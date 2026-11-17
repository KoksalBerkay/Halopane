import Combine
import CryptoKit
import Foundation
import Network
import WebKit

/// How a cloud gaming site is loaded: web app, desktop or mobile.
enum CloudGamingProfile: String, CaseIterable, Identifiable {
    case desktop, mobile, webApp
    var id: Self { self }

    var label: String {
        switch self {
        case .desktop:
            return "Desktop"
        case .mobile:
            return "Mobile"
        case .webApp:
            return "Web app"
        }
    }

    static func webAppScript(services: Set<CloudGamingService>, controllerScript: String) -> String {
        let xbox = services.contains(.xbox) ? CloudGamingService.xbox.pagePredicate : "false"
        let geforce = services.contains(.geforceNow) ? CloudGamingService.geforceNow.pagePredicate : "false"
        let luna = services.contains(.luna) ? CloudGamingService.luna.pagePredicate : "false"
        return #"""
            (() => {
                const isXbox = () => \#(xbox);
                const isGeForceNow = () => \#(geforce);
                const isLuna = () => \#(luna);
                const inScope = () => isXbox() || isGeForceNow() || isLuna();
                if (!inScope()) {
                    return;
                }
                if (isXbox()) {
            """# + "\n" + xboxMediaDevicesScript + "\n" + #"""
                    }
                """# + "\n" + displayModeScript + "\n" + controllerScript + "\n})();"
    }

    // Xbox calls these methods when leaving a stream. Keep this workaround
    // on Xbox; other services get the browser's real media surface.
    private static let xboxMediaDevicesScript = #"""
            const mediaDevices = navigator.mediaDevices;
            if (typeof mediaDevices?.enumerateDevices !== 'function') {
                const enumerateDevices = () => Promise.resolve([]);
                if (mediaDevices) {
                    Object.defineProperty(mediaDevices, 'enumerateDevices', { value: enumerateDevices });
                } else {
                    // The stream UI also registers and removes devicechange listeners.
                    // Supply that interface without exposing any capture devices or APIs.
                    const unavailableDevices = new EventTarget();
                    Object.defineProperties(unavailableDevices, {
                        enumerateDevices: { value: enumerateDevices },
                        ondevicechange: { value: null, writable: true }
                    });
                    Object.defineProperty(navigator, 'mediaDevices', {
                        configurable: true, value: unavailableDevices
                    });
                }
            }
        """#

    private static let displayModeScript = #"""
            if (navigator.standalone !== true) {
                Object.defineProperty(navigator, 'standalone', { configurable: true, get: () => true });
            }
            const nativeMatchMedia = window.matchMedia.bind(window);
            window.matchMedia = function(query) {
                const result = nativeMatchMedia(query);
                const normalized = result.media.replace(/\s/g, '').toLowerCase();
                if (normalized === '(display-mode:standalone)' || normalized === '(display-mode:browser)') {
                    Object.defineProperty(result, 'matches', {
                        configurable: true, value: normalized === '(display-mode:standalone)'
                    });
                }
                return result;
            };
        """#

    static let signalsScript = """
        let visiblePads = 'unavailable';
        if (typeof navigator.getGamepads === 'function') {
            try {
                visiblePads = Array.from(navigator.getGamepads()).filter(Boolean).length;
            } catch (_) {
                visiblePads = 'blocked';
            }
        }
        const videos = Array.from(document.querySelectorAll('video'));
        return JSON.stringify({
            userAgent: navigator.userAgent,
            platform: navigator.platform,
            touchPoints: navigator.maxTouchPoints,
            standalone: navigator.standalone ?? null,
            standaloneMedia: matchMedia('(display-mode: standalone)').matches,
            browserMedia: matchMedia('(display-mode: browser)').matches,
            rtc: typeof window.RTCPeerConnection,
            enumerateDevices: typeof navigator.mediaDevices?.enumerateDevices,
            gamepadAPI: typeof navigator.getGamepads,
            visiblePads,
            focused: document.hasFocus(),
            visibility: document.visibilityState,
            videos: videos.length,
            readyVideos: videos.filter(v => v.readyState >= 2).length,
            playingVideos: videos.filter(v => !v.paused && v.readyState >= 2).length,
            videoErrors: [...new Set(videos.flatMap(v => v.error ? [v.error.code] : []))]
        });
        """
}

/// The supported cloud gaming sites.
enum CloudGamingService: CaseIterable, Hashable {
    case xbox, geforceNow, luna

    var label: String {
        switch self {
        case .xbox:
            return "Xbox Cloud Gaming"
        case .geforceNow:
            return "GeForce NOW"
        case .luna:
            return "Amazon Luna"
        }
    }
    var preferenceKey: String {
        switch self {
        case .xbox:
            return "viture.browser.xboxProfile"
        case .geforceNow:
            return "viture.browser.geforceNowProfile"
        case .luna:
            return "viture.browser.lunaProfile"
        }
    }
    var overrideHosts: [String] {
        switch self {
        case .xbox:
            return ["xbox.com", "play.xbox.com"]
        case .geforceNow:
            return ["play.geforcenow.com"]
        case .luna:
            return ["luna.amazon.com"]
        }
    }
    static let xboxAlternateAddress = "https://play.xbox.com/"
    private static let xboxPath = #"^/(?:[a-z]{2,3}(?:-[a-z0-9]{2,8})*/)?play(?:/|$)"#

    var pagePredicate: String {
        switch self {
        case .xbox:
            return """
                location.origin === 'https://play.xbox.com' ||
                (['https://xbox.com', 'https://www.xbox.com'].includes(location.origin) &&
                 new RegExp('\(Self.xboxPath)', 'i').test(location.pathname))
                """
        case .geforceNow:
            return "location.origin === 'https://play.geforcenow.com'"
        case .luna:
            return "location.origin === 'https://luna.amazon.com'"
        }
    }

    static func page(_ url: URL?) -> Self? {
        guard let url, url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
            url.user == nil, url.password == nil, let host = url.host?.lowercased()
        else {
            return nil
        }
        if host == "play.geforcenow.com" {
            return .geforceNow
        }
        if host == "luna.amazon.com" {
            return .luna
        }
        if host == "play.xbox.com" {
            return .xbox
        }
        guard host == "xbox.com" || host == "www.xbox.com" else {
            return nil
        }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.range(of: Self.xboxPath, options: [.regularExpression, .caseInsensitive]) != nil ? .xbox : nil
    }
}
