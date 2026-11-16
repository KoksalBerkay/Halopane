import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Per-site settings: website layout, Safari user agent and ad blocking.
extension BrowserScreen {
    var websiteLayoutMenuTitle: String {
        if cloudManagesWebsiteLayout(web.url) {
            return "Layout managed by cloud profile"
        }
        return websiteLayout(web.url).toggleTitle
    }

    var safariMenuTitle: String {
        usesSafari(web.url) ? "Stop identifying as Safari" : "Identify as Safari"
    }

    func usesSafari(_ url: URL?) -> Bool {
        XWebCompatibility.usesSafari(url, override: siteDomain(url).flatMap { workspace.safariSites[$0] })
    }

    // Sets the user agent for a page about to load, using the per-site choice if there is one.
    func prepareUserAgent(_ view: WKWebView, url: URL?) {
        let override = siteDomain(url).flatMap { workspace.safariSites[$0] }
        XWebCompatibility.prepare(view, url: url, desktop: websiteLayout(url) == .desktop, override: override)
    }

    var adsEnabledForCurrentSite: Bool {
        wantsAds(web.url)
    }

    private func siteDomain(_ url: URL?) -> String? {
        url?.host?.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
    }

    private func cloudManagesWebsiteLayout(_ url: URL?) -> Bool {
        if let service = CloudGamingService.page(url) {
            return cloudProfile(service) != .desktop
        }
        return false
    }

    func websiteLayout(_ url: URL?) -> BrowserDestination.WebsiteLayout {
        if cloudManagesWebsiteLayout(url) {
            return .mobile
        }
        return BrowserDestination.websiteLayout(
            url, overrides: workspace.desktopSites, preferDesktop: workspace.preferDesktop)
    }

    private func wantsAds(_ url: URL?) -> Bool {
        owner.adsEnabled && (siteDomain(url).map { !workspace.adSettings.state.sites.contains($0) } ?? true)
    }

    func toggleSiteDesktop() {
        guard let host = BrowserDestination.layoutPreferenceHost(web.url) else {
            showNotice("Open a site first.")
            return
        }
        guard !cloudManagesWebsiteLayout(web.url) else {
            showNotice("Change the cloud profile in Settings on iPhone.")
            return
        }
        workspace.desktopSites[host] = websiteLayout(web.url) != .desktop
        UserDefaults.standard.set(workspace.desktopSites, forKey: "viture.browser.desktopSites")
        reloadPage()
    }

    // Saves only choices that differ from the built-in list, so list updates still reach other sites.
    func toggleSiteSafari() {
        guard let url = web.url, BrowserDestination.isWebURL(url), let host = siteDomain(url) else {
            showNotice("Open a site first.")
            return
        }
        let wanted = !usesSafari(url)
        workspace.safariSites[host] = nil
        if XWebCompatibility.usesSafari(url) != wanted {
            workspace.safariSites[host] = wanted
        }
        UserDefaults.standard.set(workspace.safariSites, forKey: "viture.browser.safariSites")
        prepareUserAgent(web, url: url)
        showNotice(wanted ? "This site now sees Safari." : "This site now sees the Halopane browser.")
        reloadPage()
    }

    func toggleSiteAds() {
        guard let host = siteDomain(web.url) else {
            showNotice("Open a site first.")
            return
        }
        guard owner.adsEnabled else {
            showNotice("Ad blocking is off in Settings.")
            return
        }
        guard workspace.adSettings.busy == nil else {
            showNotice("Ad blocking is updating. Try again shortly.")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.workspace.adSettings.toggleSite(host)
            if self.siteDomain(self.web.url) == host, !self.phonePageActive {
                self.reloadPage()
            }
        }
    }

    func updateAdSettings() {
        (owner.allPanels + (workspace.closedPanel.map { [$0] } ?? [])).forEach {
            $0.applyContentRules(for: $0.web.url)
        }
    }

    func applyContentRules(for url: URL?) {
        var desired: [WKContentRuleList] = []
        if wantsAds(url) {
            if workspace.adSettings.state.bundledEnabled, let general = workspace.contentBlocker.list {
                desired.append(general)
            }
            if let local = workspace.contentBlocker.localRules {
                desired.append(local)
            }
            desired.append(contentsOf: workspace.adSettings.activeLists)
        }
        let controller = web.configuration.userContentController
        for old in installedRules where !desired.contains(where: { $0 === old }) {
            controller.remove(old)
        }
        for new in desired where !installedRules.contains(where: { $0 === new }) {
            controller.add(new)
        }
        installedRules = desired
    }
}
