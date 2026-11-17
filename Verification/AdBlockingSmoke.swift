import AppKit
import Darwin
import Foundation
import SpatialMath
import WebKit

@main enum AdBlockingSmoke {
    static var windows = [NSWindow]()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                fputs("Verification failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        let base = URL(string: args[1])!
        let prefix = "HalopaneVerify-" + UUID().uuidString
        var lists = [String]()
        defer {
            for key in lists {
                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: key) { _ in }
            }
        }

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 625), configuration: cfg)
        display(web)
        let url = base.appendingPathComponent("web-probe.html")
        try await load(url, web)
        let control = await reaches(web, "check=control")
        try expect(control, "control request did not reach the server")

        let rules = try ContentRuleConversion.convert(
            Data(
                """
                ||127.0.0.1/probe-ad.png$image
                ##.halopane-smoke-ad
                """.utf8))
        let blockID = prefix + "-block"
        lists.append(blockID)
        let blocker = try await AdBlockingStore.compile(
            identifier: blockID, json: String(decoding: try rules.json(), as: UTF8.self))
        cfg.userContentController.add(blocker)
        try await load(url, web)
        let blocked = await reaches(web, "check=blocked")
        try expect(!blocked, "request was not blocked")
        let hidden =
            try await web.callAsyncJavaScript(
                """
                const e = document.createElement('div');
                e.className = 'halopane-smoke-ad';
                document.body.append(e);
                return getComputedStyle(e).display;
                """, arguments: [:], in: nil, contentWorld: .page) as? String
        try expect(hidden == "none", "custom cosmetic rule did not hide element")
        print(
            "Mac WebKit: custom network rule blocked a request and its CSS rule hid an element on the bundled fixture.")

        let exception = try ContentRuleConversion.convert(Data("@@||127.0.0.1/probe-ad.png$image".utf8))
        let exceptionID = prefix + "-exception"
        lists.append(exceptionID)
        let separate = try await AdBlockingStore.compile(
            identifier: exceptionID, json: String(decoding: try exception.json(), as: UTF8.self))
        cfg.userContentController.add(separate)
        try await load(url, web)
        let escaped = await reaches(web, "check=separate")
        try expect(!escaped, "independent exception bypassed another list")
        cfg.userContentController.remove(blocker)
        cfg.userContentController.remove(separate)
        let together = try ContentRuleConversion.convert(
            Data(
                """
                ||127.0.0.1/probe-ad.png$image
                @@||127.0.0.1/probe-ad.png$image
                """.utf8))
        let togetherID = prefix + "-together"
        lists.append(togetherID)
        let combined = try await AdBlockingStore.compile(
            identifier: togetherID, json: String(decoding: try together.json(), as: UTF8.self))
        cfg.userContentController.add(combined)
        try await load(url, web)
        let permitted = await reaches(web, "check=same")
        try expect(permitted, "same-list exception did not unblock")
        cfg.userContentController.remove(combined)
        print("Mac WebKit: @@ unblocked the matching request in the same list, and did not unblock another list.")

        if args.count > 2 {
            let iconData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            let sites = try JSONSerialization.jsonObject(with: iconData) as! [[String: String]]
            try await load(base.appendingPathComponent("home.html"), web)
            let rendered =
                try await web.callAsyncJavaScript(
                    """
                    vxrHomeSetup(sites);
                    const images = [...document.querySelectorAll('.badge img')];
                    await Promise.all(images.map(i=>i.decode().catch(()=>{})));
                    return JSON.stringify(images.map(i=>i.naturalWidth>0 && i.getBoundingClientRect().width>0));
                    """, arguments: ["sites": sites], in: nil, contentWorld: .page) as? String ?? "[]"
            let icons = (try? JSONDecoder().decode([Bool].self, from: Data(rendered.utf8))) ?? []
            print(
                "Mac WebKit Home: \(icons.filter{$0}.count)/\(sites.count) logos decoded and laid out on actual tiles.")
            try expect(icons.count == sites.count && icons.allSatisfy { $0 }, "one or more logos did not render")
        }

        let navigation = try ContentRuleConversion.convert(Data("||127.0.0.1^$document".utf8))
        let navigationID = prefix + "-navigation"
        lists.append(navigationID)
        let navigationBlocker = try await AdBlockingStore.compile(
            identifier: navigationID, json: String(decoding: try navigation.json(), as: UTF8.self))
        cfg.userContentController.add(navigationBlocker)
        let watcher = NavigationObserver()
        web.navigationDelegate = watcher
        let blockedURL = URL(string: "web-probe.html?main=block", relativeTo: base)!.absoluteURL
        web.load(URLRequest(url: blockedURL, cachePolicy: .reloadIgnoringLocalCacheData))
        for _ in 0..<100 {
            if watcher.finished || watcher.failed {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try expect(watcher.failed && !watcher.finished, "the editor's domain rule did not block a main navigation")
        cfg.userContentController.remove(navigationBlocker)
        web.navigationDelegate = nil
        print("Mac WebKit: the editor’s domain shortcut blocked a main navigation.")

        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + "-settings")
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        let fixtureStorage = fixtureDirectory.appendingPathComponent("settings.json")
        let editorStore = AdBlockingStore(storage: fixtureStorage)
        await editorStore.saveEditor("||ads.example.com^")
        try expect(
            editorStore.message?.hasPrefix("Rules added: 1. Skipped as unsupported: 0") == true,
            "rule import counts missing")
        try expect(
            editorStore.report.contains("Ad source 1 (editor): 1 rules, 0 skipped, 0 exceptions; active"),
            "source counts or status missing from the report"
        )
        try expect(!editorStore.report.contains("example.com"), "report includes a custom rule domain")
        let backup = fixtureDirectory.appendingPathComponent("backup.json")
        try editorStore.export().write(to: backup)
        let restored = AdBlockingStore(storage: fixtureDirectory.appendingPathComponent("restored.json"))
        await restored.restore(backup)
        try expect(
            restored.message?.hasPrefix("Lists restored: 1. Rules added: 1. Skipped: 0") == true,
            "restore counts missing")
        await restored.reset()
        await editorStore.reset()

        if args.count > 3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let store = AdBlockingStore(storage: directory.appendingPathComponent("settings.json"))
            await store.restore(URL(fileURLWithPath: args[3]))
            try expect(
                store.userSources.count == 1 && store.activeLists.count == 1,
                "private backup did not compile and activate")
            let source = store.userSources[0]
            await store.setEnabled(source.id, false)
            try expect(store.activeLists.isEmpty, "disabled list stayed active")
            await store.setEnabled(source.id, true)
            try expect(store.activeLists.count == 1, "list did not re-enable")
            let restarted = AdBlockingStore(storage: directory.appendingPathComponent("settings.json"))
            await restarted.load()
            try expect(restarted.activeLists.count == 1, "saved list did not reload")
            await restarted.reset()
            print(
                "Mac WebKit: imported the private backup, toggled the list, and loaded it from disk; contents not logged."
            )
        }

        var panels = [WKWebView]()
        for _ in 0..<4 {
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 625), configuration: cfg)
            display(view)
            try await load(url, view)
            panels.append(view)
        }
        let baseline = rss()
        var output = [WKContentRuleList]()
        let overall = CFAbsoluteTimeGetCurrent()
        for i in 1...5 {
            let start = CFAbsoluteTimeGetCurrent()
            let id = prefix + "-large-" + String(i)
            lists.append(id)
            let fixture = (0..<40_000).map { "||ads\($0).list\(i).example.com^$image" }.joined(separator: "\n")
            let converted = try ContentRuleConversion.convert(Data(fixture.utf8))
            let json = String(decoding: try converted.json(), as: UTF8.self)
            let timeForCompile = CFAbsoluteTimeGetCurrent()
            output.append(try await AdBlockingStore.compile(identifier: id, json: json))
            print(
                String(
                    format: "List %d: %d rules, conversion %.3f s, WebKit compile %.3f s", i, converted.entries.count,
                    timeForCompile - start, CFAbsoluteTimeGetCurrent() - timeForCompile))
        }
        for view in panels {
            for list in output {
                view.configuration.userContentController.add(list)
            }
            try await load(url, view)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print(
            String(
                format:
                    "5 × 40,000 rules active in 4 WebKit panels. Total %.2f s; app process RSS %.1f → %.1f MiB (excludes separate WebKit processes).",
                CFAbsoluteTimeGetCurrent() - overall, baseline, rss()))
    }

    final class NavigationObserver: NSObject, WKNavigationDelegate {
        var finished = false
        var failed = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
        }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            failed = true
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed = true
        }
    }

    @MainActor static func display(_ web: WKWebView) {
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        windows.append(window)
    }

    @MainActor static func load(_ url: URL, _ web: WKWebView) async throws {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        _ = web.load(request)
        for _ in 0..<150 {
            try await Task.sleep(nanoseconds: 30_000_000)
            if !web.isLoading, web.url?.path == url.path {
                return
            }
        }
        throw TestFailure("fixture navigation timed out")
    }

    @MainActor static func reaches(_ web: WKWebView, _ query: String) async -> Bool {
        let result = try? await web.callAsyncJavaScript(
            """
            return await new Promise(resolve => {
                const img = new Image();
                img.onload = () => resolve(true); img.onerror = () => resolve(false);
                img.src = 'probe-ad.png?' + query;
            });
            """, arguments: ["query": query], in: nil, contentWorld: .page)
        return result as? Bool == true
    }

    static func expect(_ ok: Bool, _ failure: String) throws {
        if !ok {
            throw TestFailure(failure)
        }
    }
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) {
            description = text
        }
    }
    static func rss() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Double(info.resident_size) / 1_048_576
    }
}
