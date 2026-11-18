import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Loading pages, the Home page, and WKNavigationDelegate.
extension BrowserScreen {
    func renderHomeShortcuts() {
        guard isHome else {
            return
        }
        var sites = workspace.homeShortcuts.items.map(\.fields)
        sites += [
            ["name": "Open Files", "action": "files", "group": "Files", "monogram": "F"],
            ["name": "Open Photos", "action": "photos", "group": "Files", "monogram": "P"]
        ]
        web.callAsyncJavaScript(
            "globalThis.vxrHomeSetup?.(sites);", arguments: ["sites": sites],
            in: nil, in: .page, completionHandler: nil)
    }

    private func finishHomeLoad() {
        homeStatus = nil
        lastHomeCursor = nil
        renderHomeShortcuts()
    }

    func addCurrentPageToHome() {
        guard let url = safeSavedAddress(web.url) else {
            showNotice("Open a page you want to save.")
            return
        }
        let title = web.title ?? siteLabel
        let store = workspace.homeShortcuts
        let query = """
            Array.from(document.querySelectorAll('link[rel]')).filter(link =>
                link.relList.contains('icon') || link.relList.contains('apple-touch-icon') ||
                link.relList.contains('apple-touch-icon-precomposed')).slice(0,12).map(link => link.href)
            """
        web.evaluateJavaScript(query) { [weak self] result, _ in
            let icons = (result as? [String] ?? []).compactMap { URL(string: $0) }
            if store.add(title: title, address: url, group: "Saved", declaredIcons: icons) {
                self?.showNotice("Added to Home.")
            } else {
                self?.showNotice("This page is already on Home, or Home is full.")
            }
        }
    }

    func loadHome() {
        navigationFinished = false
        didAttemptProcessReload = false
        guard let url = Bundle.main.url(forResource: "home", withExtension: "html") else {
            loadFixture()
            return
        }
        cancelTaps()
        cancelScroll()
        closePhoneEditor()
        moreOpen = false
        bookmarksOpen = false
        historyOpen = false
        lastRecordedAddress = nil
        homeStatus = nil
        sourceReady = true
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func loadFixture() {
        cancelTaps()
        native.archive("Page changing")
        native.cancel("Page changed")
        guard let url = Bundle.main.url(forResource: "web-probe", withExtension: "html") else {
            status = "Bundled page missing"
            return
        }
        cancelRun("Page changed")
        epoch = UUID()
        sourceReady = true
        diagnostics.videoEvidence = "Unencrypted local synthetic H.264 video; not a DRM test"
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func updateNavigation() {
        canOpenSignInOnPhone = BrowserDestination.supportsDirectPhoneSignIn(web.url)
        canBack = web.canGoBack
        canForward = web.canGoForward
        if let localFile, localFile.matches(web.url) {
            pageAddress = localFile.title
            return
        }
        pageAddress =
            isHome ? "Home" : web.url?.isFileURL == true ? "VITURE start page" : (web.url?.absoluteString ?? "")
    }

    func navigate(_ text: String) {
        didAttemptProcessReload = false
        guard let url = BrowserDestination.resolve(text, searchEngine: workspace.searchEngine) else {
            inputStatus = "Enter a web address or search."
            return
        }
        urlText = url.absoluteString
        loadURL()
    }

    func goBack() {
        if web.canGoBack {
            cancelTaps()
            closePhoneEditor()
            web.goBack()
        }
    }

    func goForward() {
        if web.canGoForward {
            cancelTaps()
            closePhoneEditor()
            web.goForward()
        }
    }

    func reloadPage() {
        if let localFile, localFile.matches(web.url), localFile.kind == .movie {
            loadLocalFile(localFile)
            return
        }
        didAttemptProcessReload = false
        cancelTaps()
        closePhoneEditor()
        web.reload()
    }

    func resetZoomAndRefresh() {
        if canZoomLocalPhoto {
            zoomLocalPhoto(by: 1 / localPhotoZoom)
            showNotice("Photo fitted to the screen.")
            return
        }
        cancelTaps()
        cancelScroll()
        closePhoneEditor()
        addressEditing = false
        bookmarksOpen = false
        historyOpen = false
        moreOpen = false
        media.setCinema(false)
        if media.nativeFullscreen {
            media.exitNativeFullscreen()
        }
        web.endEditing(true)
        web.pageZoom = 1
        let scroll = web.scrollView
        scroll.setZoomScale(max(scroll.minimumZoomScale, min(1, scroll.maximumZoomScale)), animated: false)
        media.trace("manual zoom reset and surface refresh")
        restoreSurface()
        showNotice("Zoom reset. Screen refreshed.")
    }

    func loadURL() {
        cancelTaps()
        native.archive("Page changing")
        native.cancel("Page changed")
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text),
            ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else {
            status = "Enter a web address"
            return
        }
        cancelRun("Page changed")
        epoch = UUID()
        sourceReady = true
        diagnostics.videoEvidence =
            "Custom page. Protected playback requires independent source and visual confirmation."
        web.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === web {
            cloudController.stop(web: web)
            stereoPacking = nil
            stereoSwapEyes = false
            conversion.stop()
            drawingStereoVideo = false
            cloudPage.id = UUID()
            cloudPage.service = nil
            cloudPage.profile = nil
            media.reset()
            navigationFinished = false
            backdropQuery += 1
            isLoadingPage = true
            cancelTaps()
            cancelScroll()
            closePhoneEditor()
            native.cancel("Page navigation interrupted the input check.")
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === web else {
            if webView === popup {
                updatePopupSignInInput(for: webView.url, preferences: webView.configuration.preferences)
            }
            return
        }
        if let localFile {
            if localFile.matches(webView.url) {
                pendingLocalNavigation = nil
            } else if pendingLocalNavigation == nil || pendingLocalNavigation === navigation {
                pendingLocalNavigation = nil
                self.localFile = nil
            }
        }
        cloudPage.service = CloudGamingService.page(webView.url)
        cloudPage.profile = cloudPage.service.map { cloudProfile($0) }
        recordCloudNavigation("committed", url: webView.url)
        browserNotice = ""
        status = ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView !== web {
            popupHost = webView.url?.host ?? "In-app page"
            return
        }
        navigationFinished = true
        updateNavigation()
        needsProcessReload = false
        isLoadingPage = false
        status = "Page loaded."
        keyboardText = ""
        resetCounters()
        recordVisit(allowTitle: true)
        finishHomeLoad()
        refreshPageBackdrop()
        fitLocalMediaInPanel()
        if localFile?.isPresentation == true {
            showNotice("PowerPoint preview · use a PDF export for the original layout.")
        }
        pollCloudSignals()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    private func navigationFailed(_ view: WKWebView, navigation: WKNavigation?, error: Error) {
        guard view === web else {
            return
        }
        if let pendingLocalNavigation, pendingLocalNavigation === navigation {
            self.pendingLocalNavigation = nil
            localFile = nil
        }
        isLoadingPage = view.isLoading
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return
        }
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            return
        }
        navigationFinished = true
        status = "Page could not load. Check the address or network."
        showNotice(status)
    }

    // Recovery when the page view is lost or its web process ends.
    func restoreSurface() {
        guard active else {
            return
        }
        surfaceRevision &+= 1
        if needsProcessReload {
            needsProcessReload = false
            if let localFile, localFile.matches(web.url), localFile.kind == .movie {
                loadLocalFile(localFile)
                return
            }
            web.reload()
        }
    }

    func resetBrowserView() {
        returnSignInToGlasses()
        addressEditing = false
        closePhoneEditor()
        closePopup()
        cancelTaps()
        cancelScroll()
        bookmarksOpen = false
        media.setCinema(false)
        if media.nativeFullscreen {
            media.exitNativeFullscreen()
        }
        restoreSurface()
        if !owner.fullScreenRouting {
            owner.requestRecenter(delay: 0, reason: "Fix display")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else {
            closePopup()
            return
        }
        media.reset()
        isLoadingPage = false
        status = "Web page stopped. Use Reload if it does not return."
        cancelTaps()
        cancelScroll()
        cancelRun(status)
        native.cancel(status)
        showNotice(status)
        if !didAttemptProcessReload {
            didAttemptProcessReload = true
            needsProcessReload = true
            if UIApplication.shared.applicationState == .active {
                restoreSurface()
            }
        }
    }
}
