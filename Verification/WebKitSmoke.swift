import AppKit
import Foundation
import WebKit

@main
struct WebKitSmoke {
    static var runner: Runner?
    static func main() {
        verifyWebsiteLayout()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        runner = Runner()
        app.run()
    }
    static func verifyWebsiteLayout() {
        let mobile = URL(string: "https://m.youtube.com/watch?v=fixture")!
        let desktop = URL(string: "https://www.youtube.com/watch?v=fixture")!
        var settings = [String: Bool]()
        func layout(_ url: URL, preferDesktop: Bool = false) -> BrowserDestination.WebsiteLayout {
            BrowserDestination.websiteLayout(url, overrides: settings, preferDesktop: preferDesktop)
        }
        // YouTube opens as the desktop site unless the viewer chose otherwise.
        precondition(layout(mobile).contentMode == .desktop)
        precondition(layout(mobile).toggleTitle == "Use mobile site")
        settings[BrowserDestination.layoutPreferenceHost(mobile)!] = true
        precondition(layout(desktop).contentMode == .desktop)
        precondition(layout(desktop).toggleTitle == "Use mobile site")
        settings[BrowserDestination.layoutPreferenceHost(desktop)!] = false
        settings["m.youtube.com"] = true
        precondition(layout(mobile, preferDesktop: true).contentMode == .mobile)
        precondition(layout(mobile).toggleTitle == "Use desktop site")
        settings.removeValue(forKey: "youtube.com")
        precondition(layout(desktop).contentMode == .desktop)
        let lookalike = URL(string: "https://m.youtube.com.example/")!
        precondition(layout(lookalike).contentMode == .recommended)
        print("Website layout verified: YouTube desktop default, toggle labels, and saved site preferences")
    }
    final class Runner: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let web: WKWebView
        let window: NSWindow
        var observedMessages = 0
        let mediaWorld = WKContentWorld.world(name: "VitureBrowserMedia")
        var videoID: Int?
        var cinemaRequested = false
        let scrollWorld = WKContentWorld.world(name: "VitureTrackpadScroll")
        override init() {
            let configuration = WKWebViewConfiguration()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            // Match the app, which turns element fullscreen off and routes requests to Cinema.
            if #available(macOS 12.3, *) {
                configuration.preferences.isElementFullscreenEnabled = false
            }
            let resources = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
            let observer = try! String(
                contentsOf: resources.appendingPathComponent("input-observer.js"), encoding: .utf8)
            configuration.userContentController.addUserScript(
                WKUserScript(source: observer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            let scroll = try! String(
                contentsOf: resources.appendingPathComponent("trackpad-scroll.js"), encoding: .utf8)
            configuration.userContentController.addUserScript(
                WKUserScript(source: scroll, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: scrollWorld))
            let media = try! String(contentsOf: resources.appendingPathComponent("browser-media.js"), encoding: .utf8)
            let fullscreen = try! String(
                contentsOf: resources.appendingPathComponent("browser-fullscreen.js"), encoding: .utf8)
            configuration.userContentController.addUserScript(
                WKUserScript(source: media, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: mediaWorld))
            configuration.userContentController.addUserScript(
                WKUserScript(source: fullscreen, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 625), configuration: configuration)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 625), styleMask: [.titled], backing: .buffered,
                defer: false)
            super.init()
            configuration.userContentController.add(self, name: "vxrInputProbe")
            configuration.userContentController.add(self, contentWorld: mediaWorld, name: "vxrMedia")
            configuration.userContentController.add(self, name: "vxrCinema")
            web.navigationDelegate = self
            web.uiDelegate = self
            window.contentView = web
            window.title = "VITURE fixture verification"
            window.orderBack(nil)
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                self.finish("Timed out", code: 1)
            }
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            // Drive the same WebKit policy through a local navigation without opening another app.
            guard EmbeddedNavigationPolicy.stayInWebView != .cancel else {
                finish("Embedded WebKit policy could not be constructed", code: 1)
                return
            }
            decisionHandler(EmbeddedNavigationPolicy.stayInWebView, preferences)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebFixtureLocator.locate("count", in: web) { result in
                guard case .success(let point) = result, self.web.bounds.contains(point) else {
                    self.finish("Fixture target missing: count (lookup result: \(result))", code: 1)
                    return
                }
                print("Fixture counter located in WKWebView")
                WebFixtureLocator.locate("intentionally-absent", in: self.web) { result in
                    guard case .failure(WebFixtureLocator.Failure.missing("intentionally-absent")) = result else {
                        self.finish("Missing element was not distinguished: \(result)", code: 1)
                        return
                    }
                    self.verifyTrackpadScroll()
                }
            }
        }
        func verifyTrackpadScroll() {
            web.callAsyncJavaScript(
                """
                const inner = document.getElementById('inner');
                inner.scrollIntoView({block:'center',behavior:'instant'});
                const r = inner.getBoundingClientRect();
                const outer = scrollY;
                vxrScrollStart((r.left + r.width/2)/innerWidth, (r.top + r.height/2)/innerHeight);
                vxrScrollBy(90);
                const nestedMoved = inner.scrollTop === 90 && scrollY === outer;
                vxrScrollBy(-300);
                const contained = inner.scrollTop === 0 && scrollY === outer;
                document.getElementById('rows').firstElementChild.scrollIntoView({block:'center',behavior:'instant'});
                const before = scrollY;
                vxrScrollStart(0.5,0.5);
                vxrScrollBy(70);
                const pageMoved = scrollY === before + 70;
                scrollTo(0,0);
                return nestedMoved && contained && pageMoved;
                """, arguments: [:], in: nil, in: scrollWorld
            ) { result in
                guard case .success(let value) = result, value as? Bool == true else {
                    self.finish("Trackpad scroll target check failed: \(result)", code: 1)
                    return
                }
                print("Trackpad scroll verified in WebKit: inner region, contained edge, and page")
                self.verifyActions()
            }
        }
        func verifyActions() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.web.evaluateJavaScript(
                    """
                    document.getElementById('entry').dispatchEvent(new KeyboardEvent('keydown',{bubbles:true,key:'PRIVATE_TEST_DATA'}));document.getElementById('entry').dispatchEvent(new InputEvent('input',{bubbles:true,data:'PRIVATE_TEST_DATA'}));document.getElementById('count').click();document.getElementById('activation').click();document.getElementById('entry').value='fixture smoke';document.querySelector('a').click();JSON.stringify(window.__vxrMetrics())
                    """
                ) { value, error in
                    guard let text = value as? String, let data = text.data(using: .utf8),
                        let metrics = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                        (metrics["clicks"] as? Int) == 1, (metrics["textLength"] as? Int) == 13,
                        (metrics["videoTime"] as? Double ?? 0) > 0
                    else {
                        self.finish(
                            "Fixture actions/video clock failed: \(String(describing:value)) \(String(describing:error))",
                            code: 1);
                        return
                    }
                    print("macOS WebKit fixture metrics: " + text)
                    self.web.evaluateJavaScript("JSON.stringify(window.__vxrInputEvidence)") { value, _ in
                        let evidence = value as? String ?? ""
                        guard !evidence.contains("PRIVATE_TEST_DATA"), self.observedMessages > 0 else {
                            self.finish("Observer privacy or native bridge check failed", code: 1)
                            return
                        }
                        print("Mac observer evidence (DOM control): \(evidence)")
                        print(
                            "Mac observer bridge delivered \(self.observedMessages) sanitized messages; test key/data payload excluded"
                        )
                    }
                    self.web.evaluateJavaScript("location.hash") { value, _ in
                        guard (value as? String) == "#rows" else {
                            self.finish("Link following failed", code: 1)
                            return
                        }
                        self.web.evaluateJavaScript("window.scrollTo(0,0)") { _, _ in
                            self.verifyMedia()
                        }
                    }
                }
            }
        }
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            print("Mac DOM control reached popup delegate; no window created")
            return nil
        }
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            if message.name == "vxrCinema" {
                cinemaRequested = true
                return
            }
            guard let body = message.body as? [String: Any], body["kind"] is String else {
                return
            }
            if message.name == "vxrMedia" {
                if body["kind"] as? String == "video" {
                    videoID = body["id"] as? Int
                }
                return
            }
            let json =
                (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard !json.contains("PRIVATE_TEST_DATA") else {
                finish("Native observer leaked test key/data", code: 1)
                return
            }
            observedMessages += 1
        }
        func verifyMedia() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let id = self.videoID else {
                    self.finish("No video reported by media script", code: 1)
                    return
                }
                self.web.callAsyncJavaScript(
                    """
                    const video = document.querySelector('video');
                    // Desktop YouTube checks fullscreenEnabled and calls requestFullscreen on its player.
                    if (!document.fullscreenEnabled || typeof video.parentElement.requestFullscreen !== 'function') {
                        return false;
                    }
                    await video.parentElement.requestFullscreen();
                    return !document.fullscreenElement;
                    """, arguments: [:], in: nil, in: .page
                ) { result in
                    guard case .success(let value) = result, value as? Bool == true, self.cinemaRequested else {
                        self.finish("Fullscreen request was not routed to Cinema: \(result)", code: 1)
                        return
                    }
                    self.verifyMediaCommands(id: id)
                }
            }
        }
        func verifyMediaCommands(id: Int) {
            web.callAsyncJavaScript(
                """
                const video = document.querySelector('video');
                const wasPaused = video.paused;
                const wasMuted = video.muted;
                if (!(await vxrMediaCommand(id,'toggle',0)) || wasPaused === video.paused) return false;
                if (!(await vxrMediaCommand(id,'mute',0)) || wasMuted === video.muted) return false;
                if (!(await vxrMediaCommand(id,'seek',4.5)) || Math.abs(video.currentTime-4.5)>1) return false;
                // The app mutes a whole frame before recovering one interrupted video.
                if (!vxrPanelMute() || !video.muted) return false;
                if (!(await vxrMediaCommand(id,'muteAndPlay',0)) || video.paused || !video.muted) return false;
                if (!(await vxrMediaCommand(id,'unmute',0)) || video.muted) return false;
                // 2D-to-3D frame grab: a small JPEG, or a known reason it cannot read the video.
                if (vxrMediaFrame(id + 1000,64).error !== 'gone') return false;
                const frame = vxrMediaFrame(id,64);
                if (frame.image) {
                    return frame.image.startsWith('data:image/jpeg') ? 'image' : false;
                }
                return frame.error === 'crossOrigin' ? 'crossOrigin' : false;
                """, arguments: ["id": id], in: nil, in: mediaWorld
            ) { result in
                guard case .success(let value) = result, let frame = value as? String else {
                    self.finish("Media controls failed: \(result)", code: 1)
                    return
                }
                print(
                    "Media script verified: fullscreen redirect, play/pause, mute, seek, frame mute, muted resume, "
                        + "and 3D frame grab (\(frame))")
                self.verifySecondaryClick()
            }
        }
        func verifySecondaryClick() {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
            guard
                let script = try? String(
                    contentsOf: resources.appendingPathComponent("secondary-click.js"), encoding: .utf8)
            else {
                finish("Secondary-click script missing", code: 1)
                return
            }
            let setup = """
                window.vxrSecondaryEvidence = [];
                const body = '<button style="position:fixed;inset:0;width:100%;height:100%">Right-click test</button>';
                for (const [id,x,opaque] of [['vxrSameFrame',40,false],['vxrOpaqueFrame',160,true]]) {
                    const frame = document.createElement('iframe');
                    frame.id = id;
                    frame.style.cssText = 'position:fixed;top:40px;width:80px;height:70px;border:2px solid;z-index:2147483647;left:'+x+'px';
                    if (opaque) frame.setAttribute('sandbox','');
                    const loaded = new Promise(resolve => frame.onload=resolve);
                    frame.srcdoc = body;
                    document.body.append(frame);
                    await loaded;
                    if (!opaque) {
                        const button = frame.contentDocument.querySelector('button');
                        for (const type of ['pointerdown','mousedown','contextmenu','pointerup','mouseup','click']) {
                            button.addEventListener(type,event => {
                                window.vxrSecondaryEvidence.push([event.type,event.button,event.buttons,event.isTrusted]);
                                if (type === 'contextmenu') event.preventDefault();
                            });
                        }
                    }
                }
                return { x:80/innerWidth,y:70/innerHeight,opaqueX:200/innerWidth };
                """
            web.callAsyncJavaScript(setup, arguments: [:], in: nil, in: .page) { result in
                guard case .success(let value) = result, let coords = value as? [String: Double],
                    let x = coords["x"], let y = coords["y"], let opaqueX = coords["opaqueX"]
                else {
                    self.finish("Could not prepare secondary-click fixture: \(result)", code: 1)
                    return
                }
                self.web.callAsyncJavaScript(
                    script, arguments: ["fractionX": x, "fractionY": y], in: nil, in: self.scrollWorld
                ) { result in
                    guard case .success(let value) = result, (value as? String) == "page handled context menu" else {
                        self.finish("Same-origin context menu failed: \(result)", code: 1)
                        return
                    }
                    self.web.callAsyncJavaScript(
                        script, arguments: ["fractionX": opaqueX, "fractionY": y], in: nil, in: self.scrollWorld
                    ) { result in
                        guard case .success(let value) = result, (value as? String) == "cross-origin frame" else {
                            self.finish("Opaque frame guard failed: \(result)", code: 1)
                            return
                        }
                        self.web.evaluateJavaScript(
                            """
                            (() => {
                                document.getElementById('vxrSameFrame').remove();
                                document.getElementById('vxrOpaqueFrame').remove();
                                return JSON.stringify(window.vxrSecondaryEvidence);
                            })()
                            """
                        ) { value, _ in
                            let expected =
                                #"[["pointerdown",2,2,false],["mousedown",2,2,false],["contextmenu",2,2,false],["pointerup",2,0,false],["mouseup",2,0,false]]"#
                            guard (value as? String) == expected else {
                                self.finish(
                                    "Wrong secondary-click DOM event sequence: \(String(describing:value))", code: 1);
                                return
                            }
                            print(
                                "Secondary click verified in WebKit: right-button DOM events reach a same-origin frame, opaque frames are skipped"
                            )
                            self.snapshot()
                        }
                    }
                }
            }
        }
        func snapshot() {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 1000, height: 625)
            config.snapshotWidth = 1000
            let start = CFAbsoluteTimeGetCurrent()
            web.takeSnapshot(with: config) { image, error in
                let callbackMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
                guard let image, let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else {
                    self.finish("Snapshot failed: \(String(describing:error))", code: 1)
                    return
                }
                do {
                    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                } catch {
                    self.finish(error.localizedDescription, code: 1)
                    return
                }
                self.finish(
                    String(
                        format:
                            "macOS WebKit snapshot: %d × %d pixels, %.2f ms to callback. Not an iPhone measurement.",
                        bitmap.pixelsWide, bitmap.pixelsHigh, callbackMilliseconds), code: 0)
            }
        }
        func finish(_ message: String, code: Int32) {
            print(message)
            window.close()
            Darwin.exit(code)
        }
    }
}
