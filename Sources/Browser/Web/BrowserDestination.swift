import Combine
import CryptoKit
import Foundation
import Network
import WebKit

/// Sign-in services that open on the phone.
enum PhoneSignInProvider: Equatable {
    case google, microsoft, apple, github, facebook, discord, amazon
}

/// Search engines for the address bar.
enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo = "DuckDuckGo", google = "Google", brave = "Brave", startPage = "Startpage"
    case bing = "Bing", yahoo = "Yahoo", yandex = "Yandex", ecosia = "Ecosia"
    static let preferenceKey = "viture.browser.searchEngine"
    var id: Self { self }

    func searchURL(for query: String) -> URL? {
        let endpoint: String
        let parameter: String
        switch self {
        case .duckDuckGo:
            (endpoint, parameter) = ("https://duckduckgo.com/", "q")
        case .google:
            (endpoint, parameter) = ("https://www.google.com/search", "q")
        case .brave:
            (endpoint, parameter) = ("https://search.brave.com/search", "q")
        case .startPage:
            (endpoint, parameter) = ("https://www.startpage.com/sp/search", "query")
        case .bing:
            (endpoint, parameter) = ("https://www.bing.com/search", "q")
        case .yahoo:
            (endpoint, parameter) = ("https://search.yahoo.com/search", "p")
        case .yandex:
            (endpoint, parameter) = ("https://yandex.com/search/", "text")
        case .ecosia:
            (endpoint, parameter) = ("https://www.ecosia.org/search", "q")
        }
        var url = URLComponents(string: endpoint)
        url?.queryItems = [URLQueryItem(name: parameter, value: query)]
        if let encoded = url?.percentEncodedQuery {
            url?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        return url?.url
    }
}

/// Turns typed text into an address or a search, and decides which links stay in the browser.
enum BrowserDestination {
    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host?.isEmpty ?? true)
    }

    static func phoneSignInProvider(_ url: URL?) -> PhoneSignInProvider? {
        guard let url, url.scheme?.lowercased() == "https",
            url.port == nil || url.port == 443, url.user == nil, url.password == nil,
            let host = url.host?.lowercased()
        else {
            return nil
        }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        func isPath(_ prefix: String) -> Bool {
            path == prefix || path.hasPrefix(prefix + "/")
        }

        switch host {
        case "accounts.google.com":
            return .google
        case "login.live.com", "login.microsoftonline.com":
            return .microsoft
        case "appleid.apple.com":
            return isPath("/auth/authorize") ? .apple : nil
        case "github.com":
            return isPath("/login") || path == "/session" || isPath("/sessions/two-factor") ? .github : nil
        case "facebook.com", "www.facebook.com", "m.facebook.com":
            let versionedOAuth =
                path.range(of: #"^/v[0-9]+\.[0-9]+/dialog/oauth(?:/|$)"#, options: .regularExpression) != nil
            return path == "/login.php" || isPath("/login") || isPath("/checkpoint") || isPath("/dialog/oauth")
                || versionedOAuth ? .facebook : nil
        case "discord.com":
            return isPath("/login") || isPath("/oauth2/authorize") ? .discord : nil
        case "www.amazon.com", "www.amazon.it", "www.amazon.co.uk", "www.amazon.de", "www.amazon.fr", "www.amazon.es":
            let routes = ["/ap/signin", "/ap/oa", "/ap/cvf", "/ap/mfa"]
            return routes.contains(where: isPath) ? .amazon : nil
        default:
            return nil
        }
    }

    static func isGoogleAccountPage(_ url: URL?) -> Bool {
        phoneSignInProvider(url) == .google
    }

    static func supportsDirectPhoneSignIn(_ url: URL?) -> Bool {
        phoneSignInProvider(url) != nil
    }

    static func resolve(_ input: String, searchEngine: BrowserSearchEngine = .duckDuckGo) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        if text.contains("://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty,
                url.user == nil, url.password == nil,
                ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            else {
                return nil
            }
            return url
        }
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            let candidate = URL(string: "https://" + text), candidate.host?.contains(".") == true,
            candidate.user == nil, candidate.password == nil
        {
            return candidate
        }
        return searchEngine.searchURL(for: text)
    }
}

/// Sites that only work when the browser says it is Safari. X sends other iOS
/// WebViews to a Safari-only handoff. Streaming players pick a stream and DRM
/// path from the browser name, and without "Safari" the video never starts.
/// Other sites keep the plain WebView user agent unless the user turns it on.
enum XWebCompatibility {
    private static let hosts: Set<String> = [
        "x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"
    ]
    // Matched with their subdomains.
    private static let streamingDomains: Set<String> = [
        "pluto.tv", "hbomax.com", "max.com", "plex.tv", "tubi.tv", "disneyplus.com", "primevideo.com",
        "paramountplus.com", "peacocktv.com", "hulu.com", "netflix.com", "crunchyroll.com", "mubi.com",
        "dazn.com", "skyshowtime.com", "tv.apple.com", "tvplus.com.tr"
    ]

    /// TV+ (Turkcell) reads a Mac agent with touch points as an iPad, saves "tablet" in
    /// its deviceType cookie for a year and sends playback to its app. A real Mac has no
    /// touch points, so pages shown as Mac Safari there report none. A saved non-desktop
    /// type is reset once, since the site never replaces it.
    /// Keeps the last page errors on streaming sites for the diagnostics report. Players
    /// often catch their own failures and show nothing. Addresses and long IDs are removed.
    static var pageErrorScript: String {
        let domains = streamingDomains.sorted().map { "'\($0)'" }.joined(separator: ", ")
        return """
            (() => {
                const host = location.hostname;
                if (![\(domains)].some(domain => host === domain || host.endsWith('.' + domain))) {
                    return;
                }
                const log = window.__vxrPageErrors = [];
                const clean = value => {
                    let text;
                    try {
                        text = value instanceof Error ? value.name + ': ' + value.message : String(value);
                        if (text === '[object Object]') {
                            text = JSON.stringify(value);
                        }
                    } catch (error) {
                        text = typeof value;
                    }
                    return text.replace(/(https?|blob|data):[^\\s'"]+/g, '<url>')
                        .replace(/[A-Za-z0-9+/=_-]{32,}/g, '<id>').slice(0, 160);
                };
                const add = (kind, values) => {
                    log.push(Math.round(performance.now()) + ' ' + kind + ': ' + values.map(clean).join(' '));
                    if (log.length > 12) {
                        log.shift();
                    }
                };
                for (const kind of ['error', 'warn']) {
                    const original = console[kind];
                    console[kind] = function (...values) {
                        add(kind, values);
                        return original.apply(this, values);
                    };
                }
                addEventListener('error', event => {
                    if (event.target instanceof HTMLMediaElement) {
                        add('media', [event.target.error?.code, event.target.error?.message]);
                    } else if (event.error || event.message) {
                        add('uncaught', [event.error || event.message]);
                    }
                }, true);
                addEventListener('unhandledrejection', event => {
                    add('rejection', [event.reason]);
                });
            })()
            """
    }

    static let macTouchScript = """
        (() => {
            const host = location.hostname;
            if (host !== 'tvplus.com.tr' && !host.endsWith('.tvplus.com.tr')) {
                return;
            }
            if (!navigator.userAgent.includes('Macintosh')) {
                return;
            }
            Object.defineProperty(Navigator.prototype, 'maxTouchPoints', { get: () => 0, configurable: true });
            const saved = document.cookie.match(/(?:^|; )deviceType=([^;]*)/);
            if (!saved || saved[1] === 'desktop') {
                return;
            }
            document.cookie = 'deviceType=desktop; path=/; max-age=31536000; secure';
            try {
                if (!sessionStorage.getItem('vxrDeviceTypeReset')) {
                    sessionStorage.setItem('vxrDeviceTypeReset', '1');
                    location.reload();
                }
            } catch (error) {
            }
        })()
        """

    static func isStreaming(_ host: String) -> Bool {
        streamingDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isX(_ host: String) -> Bool {
        hosts.contains(host)
    }

    /// Whether a site is sent the Safari user agent. A per-site choice wins over the built-in list.
    static func usesSafari(_ url: URL?, override: Bool? = nil) -> Bool {
        guard let url, BrowserDestination.isWebURL(url), let host = url.host?.lowercased() else {
            return false
        }
        if let override {
            return override
        }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
            url.port == nil || url.port == 443
        else {
            return false
        }
        return hosts.contains(host) || isStreaming(host)
    }

    static func userAgent(
        for url: URL?, desktop: Bool, os: OperatingSystemVersion, override: Bool? = nil
    ) -> String? {
        guard usesSafari(url, override: override) else {
            return nil
        }
        let version = "\(os.majorVersion).\(os.minorVersion)"
        if desktop {
            return
                """
                Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \
                Version/\(version) Safari/605.1.15
                """
        }
        let platform = os.majorVersion >= 26 ? "18_7" : "\(os.majorVersion)_\(os.minorVersion)"
        return
            """
            Mozilla/5.0 (iPhone; CPU iPhone OS \(platform) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) \
            Version/\(version) Mobile/15E148 Safari/604.1
            """
    }

    static func prepare(
        _ webView: WKWebView, url: URL?, desktop: Bool, override: Bool? = nil,
        os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        let agent = userAgent(for: url, desktop: desktop, os: os, override: override)
        if webView.customUserAgent != agent {
            webView.customUserAgent = agent
        }
    }
}

// WebKit's source names this policy _WKNavigationActionPolicyAllowWithoutTryingAppLink.
// https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegatePrivate.h
enum EmbeddedNavigationPolicy {
    static let stayInWebView =
        WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .cancel
}

extension BrowserDestination {
    enum WebsiteLayout {
        case recommended, desktop, mobile

        var contentMode: WKWebpagePreferences.ContentMode {
            switch self {
            case .recommended:
                return .recommended
            case .desktop:
                return .desktop
            case .mobile:
                return .mobile
            }
        }

        var toggleTitle: String { self == .desktop ? "Use mobile site" : "Use desktop site" }
    }

    static func layoutPreferenceHost(_ url: URL?) -> String? {
        guard let url, isWebURL(url), let host = url.host?.lowercased() else {
            return nil
        }
        if host == "m.youtube.com" {
            return "youtube.com"
        }
        return host.replacingOccurrences(of: "www.", with: "", options: .anchored)
    }

    static func websiteLayout(_ url: URL?, overrides: [String: Bool], preferDesktop: Bool) -> WebsiteLayout {
        if let host = layoutPreferenceHost(url) {
            // Keep old YouTube preferences when the only saved key is the mobile host.
            let override = overrides[host] ?? (host == "youtube.com" ? overrides["m.youtube.com"] : nil)
            if let override {
                return override ? .desktop : .mobile
            }
            if desktopProfileHosts.contains(host) {
                return .desktop
            }
        }
        return preferDesktop ? .desktop : .recommended
    }

    // Site behavior is independent of whether a site has a Home shortcut.
    // These streaming services refuse iPhone browsers and send them to their apps;
    // their desktop sites play in the browser. Mobile YouTube keeps loading posts
    // at the panel size, so YouTube opens as the desktop site too.
    static let desktopProfileHosts: Set<String> = [
        "xbox.com", "play.geforcenow.com", "luna.amazon.com", "netflix.com", "disneyplus.com", "hulu.com",
        "primevideo.com", "peacocktv.com", "youtube.com", "tvplus.com.tr"
    ]
}

/// Names a site in a shared report without revealing where the user browses.
enum ReportSite {
    // Services with special handling in the app. Naming them is what makes a report useful.
    private static let services: Set<String> = [
        "youtube.com", "xbox.com", "play.geforcenow.com", "luna.amazon.com"
    ]

    static func label(_ url: URL?) -> String {
        guard let url else {
            return "Home"
        }
        if url.isFileURL {
            return "local page"
        }
        guard let host = BrowserDestination.layoutPreferenceHost(url) else {
            return "other page"
        }
        let known =
            services.contains { host == $0 || host.hasSuffix("." + $0) }
            || XWebCompatibility.isStreaming(host) || XWebCompatibility.isX(host)
            || BrowserDestination.desktopProfileHosts.contains(host)
        return known ? host : "other website"
    }
}
