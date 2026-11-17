import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Cloud gaming profiles and the game controller bridge.
extension BrowserScreen {
    static func savedCloudProfile(_ service: CloudGamingService) -> CloudGamingProfile {
        CloudGamingProfile(rawValue: UserDefaults.standard.string(forKey: service.preferenceKey) ?? "") ?? .webApp
    }

    func cloudProfile(_ service: CloudGamingService) -> CloudGamingProfile {
        switch service {
        case .xbox:
            return owner.xboxCloudProfile
        case .geforceNow:
            return owner.geforceNowProfile
        case .luna:
            return owner.lunaCloudProfile
        }
    }

    func updateCloudProfile(
        _ service: CloudGamingService, from previous: CloudGamingProfile, to current: CloudGamingProfile
    ) {
        guard previous != current else {
            return
        }
        UserDefaults.standard.set(current.rawValue, forKey: service.preferenceKey)
        for panel in allPanels + (workspace.closedPanel.map { [$0] } ?? []) {
            panel.installCloudProfileScripts()
            if CloudGamingService.page(panel.web.url) == service, !panel.phonePageActive, panel.popup == nil {
                panel.reloadPage()
            }
        }
    }

    private static let cloudControllerScript =
        Bundle.main.url(forResource: "cloud-controller", withExtension: "js")
        .flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        } ?? ""

    func installCloudProfileScripts() {
        let enabled = Set(CloudGamingService.allCases.filter { cloudProfile($0) == .webApp })
        guard enabled != installedCloudApps else {
            return
        }
        let controller = web.configuration.userContentController
        if !installedCloudApps.isEmpty {
            // Public WebKit has no remove-one API. Use fresh script objects;
            // a live process can ignore re-added objects after removal.
            controller.removeAllUserScripts()
            Self.browserScripts(media: media, scrollWorld: scrollWorld).forEach(controller.addUserScript)
        }
        if !enabled.isEmpty {
            let script = CloudGamingProfile.webAppScript(
                services: enabled, controllerScript: Self.cloudControllerScript)
            controller.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        installedCloudApps = enabled
    }

    func recordCloudNavigation(_ note: String, url: URL?) {
        guard let host = url?.host?.lowercased() else {
            return
        }
        let service: CloudGamingService
        if let target = CloudGamingService.page(url) {
            service = target
        } else if cloudPage.navigation[.xbox] != nil, Self.xboxSignInHosts.contains(host) {
            service = .xbox
        } else {
            return
        }
        let row = host + " " + note
        var history = cloudPage.navigation[service] ?? []
        guard history.last != row else {
            return
        }
        history.append(row)
        cloudPage.navigation[service] = Array(history.suffix(24))
    }

    private static let xboxSignInHosts: Set<String> = [
        "login.live.com", "account.live.com", "login.microsoftonline.com", "account.microsoft.com",
        "login.xbox.com", "sisu.xboxlive.com"
    ]

    func updateCloudController(now: CFTimeInterval) {
        guard let service = cloudPage.service, cloudPage.profile == .webApp,
            cloudProfile(service) == .webApp,
            receivesInput,
            !phonePageActive, popup == nil, !controllerSettings, !panelWarming, web.window != nil,
            UIApplication.shared.applicationState == .active, CloudGamingService.page(web.url) == service
        else {
            cloudController.stop(web: web)
            return
        }
        cloudController.update(web: web, now: now)
    }

    func pollCloudSignals() {
        guard let service = cloudPage.service, let profile = cloudPage.profile,
            CloudGamingService.page(web.url) == service, let host = web.url?.host
        else {
            return
        }
        let pageID = cloudPage.id
        let requestedMode = cloudPage.modeRequested
        web.callAsyncJavaScript(CloudGamingProfile.signalsScript, arguments: [:], in: nil, in: .page) {
            [weak self] result in
            guard let self, self.active, self.cloudPage.id == pageID,
                self.cloudPage.service == service,
                self.cloudPage.profile == profile
            else {
                return
            }
            let sample = (try? result.get()) as? String ?? "page signals unavailable"
            self.cloudPage.signals[service, default: [:]][profile, default: [:]][host] =
                "requested layout: " + requestedMode + "; " + sample
        }
    }

    private var cloudReport: String? {
        guard !cloudPage.navigation.isEmpty else {
            return nil
        }
        let sections = CloudGamingService.allCases.compactMap { service -> String? in
            guard let navigation = cloudPage.navigation[service] else {
                return nil
            }
            let overrides = service.overrideHosts.map { host in
                let mode = workspace.desktopSites[host].map { $0 ? "desktop" : "recommended" } ?? "none"
                return host + "=" + mode
            }.joined(separator: ", ")
            let signals = cloudPage.signals[service] ?? [:]
            let samples = CloudGamingProfile.allCases.flatMap { profile in
                (signals[profile] ?? [:]).sorted { $0.key < $1.key }.map { host, sample in
                    profile.label + " [" + host + "]: " + sample
                }
            }
            return
                ([service.label + "; Desktop site overrides: " + overrides, navigation.joined(separator: " | ")]
                + samples)
                .joined(separator: "\n")
        }
        return (["Panel \(panelNumber)", cloudController.report] + sections).joined(separator: "\n")
    }

    var workspaceCloudReport: String {
        let profiles = CloudGamingService.allCases.map { $0.label + " profile: " + cloudProfile($0).label }
        return (profiles + owner.allPanels.compactMap(\.cloudReport)).joined(separator: "\n")
    }
}
