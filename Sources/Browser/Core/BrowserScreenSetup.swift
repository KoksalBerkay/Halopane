import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Setup helpers used by init, and website appearance.
extension BrowserScreen {
    func setPhoneSystemAppearance(_ style: UIUserInterfaceStyle) {
        guard self === owner, style == .dark || style == .light, workspace.phoneSystemAppearance != style else {
            return
        }
        workspace.phoneSystemAppearance = style
        if workspace.websiteAppearance == .system {
            updateWebsiteAppearance()
        }
    }

    func updateWebsiteAppearance() {
        (owner.allPanels + (workspace.closedPanel.map { [$0] } ?? [])).forEach {
            $0.applyWebsiteAppearance()
        }
    }

    func applyWebsiteAppearance(to view: WKWebView? = nil) {
        let style = workspace.websiteAppearance.style(system: workspace.phoneSystemAppearance)
        for page in [view ?? web, view == nil ? popup : nil].compactMap({ $0 }) {
            if page.overrideUserInterfaceStyle != style {
                page.overrideUserInterfaceStyle = style
            }
        }
    }

    // Home page actions, cloud gaming profiles, media hooks and ad blocking.
    func setUpBrowserFeatures(owner: BrowserScreen?) {
        if owner == nil {
            LocalPanelFile.purgeOldPhotoExports()
        }
        web.configuration.userContentController.add(WeakMessageHandler(self), name: "vxrHomeAction")
        installCloudProfileScripts()
        media.attach(web)
        homeObservation = workspace.homeShortcuts.$items.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.renderHomeShortcuts()
        }
        connectMediaCallbacks()
        if owner == nil {
            startAdBlocking()
        } else {
            applyContentRules(for: nil)
        }
    }

    private func connectMediaCallbacks() {
        media.canUseCinema = { [weak self] in
            guard let self else {
                return false
            }
            return self.active && self.backend == .replica && !native.phoneHosted
        }
        media.onRecovery = { [weak self] in
            self?.restoreSurface()
        }
        media.onCinemaNotice = { [weak self] in
            self?.showNotice($0)
        }
        media.onAudioEvent = { [weak self] audible in
            guard let self else {
                return
            }
            self.owner.audioEvent(from: self, audible: audible)
        }
    }

    // Only the first panel loads the shared ad lists. Other panels reuse them.
    private func startAdBlocking() {
        workspace.adSettings.onChange = { [weak self] in
            self?.updateAdSettings()
        }
        workspace.adSettings.onFailure = { [weak self] in
            self?.selectedSession.showNotice("An ad list couldn’t load. See Settings on iPhone.")
        }
        Task { @MainActor [weak self] in
            await self?.workspace.adSettings.load()
        }
        workspace.contentBlocker.loadLocal { [weak self] in
            self?.updateAdSettings()
        }
        workspace.contentBlocker.load { [weak self] in
            guard let self else {
                return
            }
            self.updateAdSettings()
            if self.adsEnabled, self.workspace.contentBlocker.list == nil {
                self.selectedSession.showNotice("Ad blocking is unavailable.")
            }
        }
    }

    func observeNavigation() {
        navigationObservers = [
            web.observe(\.url, options: [.new]) { [weak self] view, _ in
                self?.updateNavigation()
                if !view.isLoading {
                    self?.recordVisit(allowTitle: false)
                }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                self?.updateNavigation()
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                self?.updateNavigation()
            },
            web.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
                self?.refreshPageBackdrop()
            }
        ]
    }

    // Stop input when the app goes inactive, and restore the page when it comes back.
    func observeAppLifecycle() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.media.trace("app inactive")
                if let self, self === self.owner {
                    self.recordAppActivity(active: false)
                }
                if let self {
                    self.cloudController.stop(web: self.web)
                }
                self?.cancelTaps()
                self?.cancelScroll()
                self?.addressEditing = false
                self?.closePhoneEditor()
            })
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.backgrounded = true
            })
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                if self === self.owner {
                    self.recordAppActivity(active: true)
                }
                guard self.backgrounded else {
                    return
                }
                self.backgrounded = false
                if self.phonePageActive || self.canResetPopupKeyboard {
                    self.restorePhoneSignInInput()
                } else {
                    self.restoreSurface()
                }
                self.media.trace("app active")
            })
    }

    private static func trackpadScripts(in scrollWorld: WKContentWorld) -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        if let url = Bundle.main.url(forResource: "trackpad-scroll", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        {
            scripts.append(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: scrollWorld))
        }
        scripts.append(
            WKUserScript(
                source: """
                    (() => {
                        const style = document.createElement('style');
                        style.textContent = 'html { touch-action: manipulation !important; }';
                        (document.head || document.documentElement)?.append(style);
                    })()
                    """, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        return scripts
    }

    private static func phoneEditorScripts() -> [WKUserScript] {
        guard let url = Bundle.main.url(forResource: "phone-editor", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return [
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: phoneEditorWorld)
        ]
    }

    // Draws <select> options in the page, since the native iOS menu ignores the pointer.
    private static func selectPickerScripts() -> [WKUserScript] {
        guard let url = Bundle.main.url(forResource: "select-picker", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return [
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: selectPickerWorld)
        ]
    }

    static func browserScripts(media: BrowserMedia, scrollWorld: WKContentWorld) -> [WKUserScript] {
        media.makeUserScripts() + trackpadScripts(in: scrollWorld) + phoneEditorScripts() + selectPickerScripts()
            + [pageScript(XWebCompatibility.macTouchScript), pageScript(XWebCompatibility.pageErrorScript)]
    }

    // Runs in the page world so the site sees the changed touch count and its own errors are caught.
    private static func pageScript(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }
}
