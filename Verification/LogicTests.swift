import Foundation

/// Plain checks for app logic that has no UI: typed addresses, search URLs and
/// which sign-in pages move to the phone. Run with Verification/logic-tests.sh.
@main
enum LogicTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    static func main() {
        checkAddressResolution()
        checkSearchURLs()
        checkWebURLs()
        checkPhoneSignIn()
        checkReportSites()
        if failures > 0 {
            print("\(failures) logic check(s) failed")
            exit(1)
        }
        print("Logic checks passed: address resolution, search URLs, web URLs and phone sign-in pages, report sites")
    }

    // Reports name only well-known services, never other sites.
    static func checkReportSites() {
        let label = { (address: String?) in
            ReportSite.label(address.flatMap { URL(string: $0) })
        }
        check(label("https://www.youtube.com/watch?v=abc") == "youtube.com", "YouTube is named")
        check(label("https://mybank.example/") == "other website", "other sites are not named")
        check(label("https://youtube.com.example/") == "other website", "a lookalike domain is not named")
        check(label("file:///private/var/doc.pdf") == "local page", "local files are not named")
        check(label(nil) == "Home", "no address reads as Home")
    }

    // Typed text becomes an https address when it looks like one, otherwise a search.
    static func checkAddressResolution() {
        let resolve = { (text: String) in
            BrowserDestination.resolve(text)?.absoluteString
        }
        check(resolve("example.com") == "https://example.com", "bare host gets https")
        check(resolve("  example.com/path  ") == "https://example.com/path", "spaces around an address are ignored")
        check(resolve("http://example.com") == "http://example.com", "explicit http is kept")
        check(resolve("https://example.com/a?b=c") == "https://example.com/a?b=c", "full https address is kept")
        check(resolve("") == nil, "empty input does nothing")
        check(resolve("   ") == nil, "blank input does nothing")
        check(resolve("ftp://example.com") == nil, "other schemes are refused")
        check(resolve("javascript://alert(1)") == nil, "script addresses are refused")
        check(resolve("https://user:secret@example.com") == nil, "addresses with credentials are refused")
        check(
            resolve("user:secret@example.com")?.hasPrefix("https://duckduckgo.com/") == true,
            "credentials without a scheme become a search")
        check(resolve("localhost")?.hasPrefix("https://duckduckgo.com/") == true, "a word without a dot is a search")
        check(
            resolve("hello world")?.hasPrefix("https://duckduckgo.com/?q=hello") == true, "text with spaces is a search"
        )
        let google = BrowserDestination.resolve("cats", searchEngine: .google)?.absoluteString
        check(google == "https://www.google.com/search?q=cats", "the chosen search engine is used")
    }

    static func checkSearchURLs() {
        for engine in BrowserSearchEngine.allCases {
            let url = engine.searchURL(for: "a b")
            check(url?.scheme == "https", "\(engine.rawValue) search uses https")
        }
        let plus = BrowserSearchEngine.duckDuckGo.searchURL(for: "c++")?.absoluteString
        check(plus == "https://duckduckgo.com/?q=c%2B%2B", "a plus sign is sent as a plus, not a space")
        let startPage = BrowserSearchEngine.startPage.searchURL(for: "x")?.absoluteString
        check(startPage == "https://www.startpage.com/sp/search?query=x", "Startpage uses its own parameter name")
    }

    static func checkWebURLs() {
        check(BrowserDestination.isWebURL(URL(string: "https://example.com")!), "https is a web address")
        check(BrowserDestination.isWebURL(URL(string: "HTTP://example.com")!), "the scheme is not case sensitive")
        check(!BrowserDestination.isWebURL(URL(string: "file:///tmp/a.html")!), "local files are not web addresses")
        check(!BrowserDestination.isWebURL(URL(string: "https://")!), "an address needs a host")
    }

    // Sign-in pages for these services open on the phone, where passkeys and password managers work.
    static func checkPhoneSignIn() {
        let provider = { (text: String) in
            BrowserDestination.phoneSignInProvider(URL(string: text))
        }
        check(provider("https://accounts.google.com/signin") == .google, "Google sign-in")
        check(provider("https://login.live.com/oauth") == .microsoft, "Microsoft sign-in")
        check(provider("https://appleid.apple.com/auth/authorize") == .apple, "Apple sign-in")
        check(provider("https://appleid.apple.com/account") == nil, "other Apple ID pages stay in the glasses")
        check(provider("https://github.com/login") == .github, "GitHub sign-in")
        check(provider("https://github.com/sessions/two-factor/app") == .github, "GitHub two-factor")
        check(provider("https://github.com/KoksalBerkay") == nil, "ordinary GitHub pages stay in the glasses")
        check(provider("https://www.facebook.com/v19.0/dialog/oauth") == .facebook, "versioned Facebook OAuth")
        check(provider("https://discord.com/oauth2/authorize") == .discord, "Discord sign-in")
        check(provider("https://www.amazon.it/ap/signin") == .amazon, "Amazon sign-in")
        check(provider("https://www.amazon.it/dp/B000") == nil, "Amazon product pages stay in the glasses")
        check(provider("http://accounts.google.com/signin") == nil, "plain http never moves to the phone")
        check(provider("https://accounts.google.com:8443/") == nil, "unusual ports never move to the phone")
        check(provider("https://accounts.google.com.example.com/") == nil, "lookalike hosts never move to the phone")
        check(BrowserDestination.supportsDirectPhoneSignIn(URL(string: "https://login.live.com/")), "helper agrees")
        check(!BrowserDestination.supportsDirectPhoneSignIn(nil), "no address means no sign-in page")
    }
}
