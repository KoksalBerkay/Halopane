import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Sign-in pages and popups that move to the iPhone screen.
extension BrowserScreen {
    var signInSession: BrowserScreen? {
        allPanels.first { $0.phonePageActive }
    }

    func openSignInOnPhone() {
        guard active, receivesInput, popup == nil, !phonePageActive,
            BrowserDestination.supportsDirectPhoneSignIn(web.url)
        else {
            return
        }
        cancelTaps()
        cancelScroll()
        addressEditing = false
        closePhoneEditor()
        media.setCinema(false)
        // Keep the original WKWebView and its back stack, cookies and redirect state.
        web.removeFromSuperview()
        web.transform = .identity
        web.contentScaleFactor = UIScreen.main.scale
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        webPreferences.isTextInteractionEnabled = true
        phonePageActive = true
    }

    func returnSignInToGlasses() {
        guard phonePageActive else {
            return
        }
        web.endEditing(true)
        web.removeFromSuperview()
        web.scrollView.contentInsetAdjustmentBehavior = .never
        webPreferences.isTextInteractionEnabled = false
        phonePageActive = false
        restoreSurface()
    }

    func restorePhoneSignInInput() {
        let target = canResetPopupKeyboard ? popup : phonePageActive ? web : nil
        guard let target, let window = target.window,
            window.windowScene?.session.role == .windowApplication
        else {
            return
        }
        if !window.isKeyWindow {
            window.makeKey()
        }
        // Release stale WebKit/UIKeyboard focus after resume. The page itself is not reloaded.
        target.endEditing(true)
        target.evaluateJavaScript("document.activeElement?.blur();true", completionHandler: nil)
    }

    func insertSignInCode(_ rawCode: String, completion: @escaping (Bool) -> Void) {
        guard phonePageActive, BrowserDestination.isGoogleAccountPage(web.url) else {
            completion(false)
            return
        }
        let code = rawCode.filter { !$0.isWhitespace && $0 != "-" }
        guard (4...12).contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            completion(false)
            return
        }
        web.callAsyncJavaScript(
            """
            if (location.origin !== 'https://accounts.google.com') {
                return false;
            }
            const visibleCodeField = field => field instanceof HTMLInputElement && !field.disabled &&
                !field.readOnly && field.getClientRects().length &&
                ['text','tel','number','password'].includes(field.type) &&
                (field.autocomplete.split(/\\s+/).includes('one-time-code') ||
                 /^(totppin|phonepin|idvpin|verificationcode|otpcode|otp)$/i.test(field.name) ||
                 /^(totppin|phonepin|idvpin|verificationcode|otpcode|otp)$/i.test(field.id));
            const active = document.activeElement;
            const candidates = [...document.querySelectorAll('input')].filter(visibleCodeField);
            const field = visibleCodeField(active) ? active : candidates.length === 1 ? candidates[0] : null;
            if (!field) {
                return false;
            }
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(field,code);
            field.dispatchEvent(new InputEvent('input',{bubbles:true,composed:true,inputType:'insertText'}));
            field.dispatchEvent(new Event('change',{bubbles:true}));
            return field.value === code;
            """, arguments: ["code": code], in: nil, in: editorWorld
        ) { result in
            if case .success(let value) = result {
                completion(value as? Bool == true)
            } else {
                completion(false)
            }
        }
    }

    func webView(
        _ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let fixture = webView.url?.isFileURL == true && webView.url?.lastPathComponent == "web-probe.html"
        if fixture {
            native.popupObserved(navigationAction.request.url)
            return nil  // Controlled activation signal, no popup UI during the automatic check.
        }
        if let url = navigationAction.request.url, BrowserDestination.isWebURL(url),
            navigationAction.navigationType == .linkActivated
        {
            // An ordinary new-tab link stays in the browser on the glasses.
            cancelTaps()
            webView.load(navigationAction.request)
            return nil
        }
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
            !["https", "http", "about"].contains(scheme)
        {
            return nil
        }
        let child = WKWebView(frame: .zero, configuration: configuration)
        applyWebsiteAppearance(to: child)
        child.uiDelegate = self
        child.navigationDelegate = self
        if popupSignInPreferences != nil {
            restorePopupSignInPreferences()
        }
        updatePopupSignInInput(for: navigationAction.request.url, preferences: configuration.preferences)
        cancelTaps()
        closePhoneEditor()
        popup = child
        popupHost = navigationAction.request.url?.host ?? "In-app login"
        native.log(
            """
            Website popup hosted interactively on phone; popup input is separate from the external-window injection \
            verdict.
            """
        )
        return child
    }

    func updatePopupSignInInput(for url: URL?, preferences: WKPreferences) {
        guard let provider = BrowserDestination.phoneSignInProvider(url) else {
            restorePopupSignInPreferences()
            return
        }
        if popupSignInPreferences?.preferences !== preferences {
            restorePopupSignInPreferences()
            popupSignInPreferences = (preferences, preferences.isTextInteractionEnabled)
        }
        preferences.isTextInteractionEnabled = true
        if popupSignInProvider != provider {
            popupSignInProvider = provider
        }
    }

    private func restorePopupSignInPreferences() {
        guard let saved = popupSignInPreferences else {
            return
        }
        saved.preferences.isTextInteractionEnabled =
            saved.preferences === webPreferences ? phonePageActive : saved.wasEnabled
        popupSignInPreferences = nil
        popupSignInProvider = nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popup else {
            return
        }
        restorePopupSignInPreferences()
        popup = nil
    }

    func closePopup() {
        popup?.evaluateJavaScript("window.close()", completionHandler: nil)
        restorePopupSignInPreferences()
        popup = nil
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
            !["https", "http", "file", "about", "blob", "data"].contains(scheme)
        {
            status =
                "Blocked handoff to external app scheme " + scheme
                + "; this is a provider/navigation limit, not a portal result."
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            let url = navigationAction.request.url
            let layout = websiteLayout(url)
            preferences.preferredContentMode = layout.contentMode
            XWebCompatibility.prepare(webView, url: url, desktop: layout == .desktop)
            let service = CloudGamingService.page(url)
            let mode = preferences.preferredContentMode
            let modeName = mode == .desktop ? "desktop" : mode == .mobile ? "mobile" : "recommended"
            if webView === web, service != nil {
                cloudPage.modeRequested = modeName
            }
            recordCloudNavigation("\(webView === web ? "panel" : "popup") requested \(modeName)", url: url)
            if webView === web {
                applyContentRules(for: navigationAction.request.url)
            }
        }
        if let url = navigationAction.request.url, BrowserDestination.isWebURL(url) {
            decisionHandler(EmbeddedNavigationPolicy.stayInWebView, preferences)
        } else {
            decisionHandler(.allow, preferences)
        }
    }
}
