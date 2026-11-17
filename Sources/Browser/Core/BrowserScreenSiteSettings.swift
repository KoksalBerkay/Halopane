import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Per-site settings: website layout and ad blocking.
extension BrowserScreen {
    var websiteLayoutMenuTitle: String {
        if cloudManagesWebsiteLayout(web.url) {
            return "Layout managed by cloud profile"
        }
        return websiteLayout(web.url).toggleTitle
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
