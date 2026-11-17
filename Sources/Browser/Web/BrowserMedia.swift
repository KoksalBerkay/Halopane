import Combine
import QuartzCore
import SpatialMath
import UIKit
import WebKit

/// Tracks the main video on a page, for playback controls and cinema mode.
final class BrowserMedia: NSObject, ObservableObject, WKScriptMessageHandler {
    /// What the page reported about one video.
    struct Video: Equatable {
        let id: Int
        let box: CGRect
        let time: Double
        let duration: Double
        let paused: Bool
        let muted: Bool
        let range: ClosedRange<Double>?
        let mainFrame: Bool
        let aspect: Double

        var visibleArea: CGFloat { box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)).standardized.size.area }
    }
    private struct Source {
        let key: String
        let frame: WKFrameInfo
        let video: Video
        let updated: CFTimeInterval
    }
    private var sources: [String: Source] = [:]
    private var current: Source?
    private var embeddedRects: [String: (box: CGRect, updated: CFTimeInterval)] = [:]
    private var cinemaFrameKey: String?
    private var pendingCinema: (key: String?, expiration: CFTimeInterval)?
    var onCinemaNotice: ((String) -> Void)?
    private var generation = UUID()
    private let world = WKContentWorld.world(name: "VitureBrowserMedia")
    private var fullscreenObserver: NSKeyValueObservation?
    private var lastCinemaRequest: CFTimeInterval = 0
    private var lastFrameCinemaSignal: CFTimeInterval = 0
    private var closingPresentation = false
    private var closeID = UUID()
    private var presentationGate = VideoPresentationGate()
    weak var web: WKWebView?
    var canUseCinema: () -> Bool = { false }
    private var reportingFrames: [String: (WKFrameInfo, CFTimeInterval)] = [:]
    private(set) var playbackTrace: [(time: Double, event: String)] = []
    var onAudioEvent: ((Bool) -> Void)?
    var onRecovery: (() -> Void)?
    @Published private(set) var video: Video?
    @Published private(set) var cinema = false
    @Published private(set) var nativeFullscreen = false
    var isVideoPresentation: Bool { cinema || nativeFullscreen }
    @Published private(set) var seekFailed = false
    @Published private(set) var status = ""
    private(set) var diagnostics: [String] = []

    private var scriptSources: [(source: String, world: WKContentWorld, channel: String)] {
        [("browser-media", world, "vxrMedia"), ("browser-fullscreen", WKContentWorld.page, "vxrCinema")].compactMap {
            name, world, channel in
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                let source = try? String(contentsOf: url, encoding: .utf8)
            else {
                return nil
            }
            return (source, world, channel)
        }
    }

    func configure(in config: WKWebViewConfiguration) {
        config.allowsPictureInPictureMediaPlayback = false
        config.preferences.isElementFullscreenEnabled = false
        for (_, world, channel) in scriptSources {
            config.userContentController.add(WeakMessageHandler(self), contentWorld: world, name: channel)
        }
    }

    func makeUserScripts() -> [WKUserScript] {
        scriptSources.map {
            WKUserScript(source: $0.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: $0.world)
        }
    }

    func attach(_ web: WKWebView) {
        self.web = web
        fullscreenObserver = web.observe(\.fullscreenState, options: [.new]) { [weak self] view, _ in
            guard let self else {
                return
            }
            self.note("WebKit fullscreen state \(view.fullscreenState.rawValue)")
            self.nativeFullscreen = view.fullscreenState != .notInFullscreen
            if view.fullscreenState == .inFullscreen {
                self.exitNativeFullscreen(enterCinema: true)
            }
        }
    }

    func reset() {
        generation = UUID()
        presentationGate.reset()
        closeID = UUID()
        closingPresentation = false
        nativeFullscreen = (web?.fullscreenState ?? .notInFullscreen) != .notInFullscreen
        sources.removeAll()
        reportingFrames.removeAll()
        embeddedRects.removeAll()
        cinemaFrameKey = nil
        pendingCinema = nil
        onAudioEvent?(false)
        current = nil
        video = nil
        cinema = false
        seekFailed = false
        status = ""
    }

    func refresh() {
        let now = CACurrentMediaTime()
        reportingFrames = reportingFrames.filter { now - $0.value.1 < 6 }
        sources = sources.filter { now - $0.value.updated < 3 }
        embeddedRects = embeddedRects.filter { now - $0.value.updated < 3 }
        let selected = sources.values.max {
            if $0.video.paused != $1.video.paused {
                return !$1.video.paused
            }
            return (projectedBox($0)?.size.area ?? 0) < (projectedBox($1)?.size.area ?? 0)
        }
        if let key = cinemaFrameKey, sources[key] == nil {
            setCinema(false)
            onCinemaNotice?("Cinema closed because the player changed.")
        }
        let next = (cinemaFrameKey.flatMap { sources[$0] }) ?? selected
        if current?.video.id != next?.video.id || current?.key != next?.key {
            seekFailed = false
        }
        current = next
        if video != next?.video {
            video = next?.video
        }
        if cinema && mapping == nil {
            cinema = false
            cinemaFrameKey = nil
        }
        if let request = pendingCinema {
            let target = request.key.flatMap { sources[$0] } ?? (request.key == nil ? current : nil)
            if let target, canUseCinema(), let box = projectedBox(target), box.width > 0.02, box.height > 0.03 {
                pendingCinema = nil
                cinemaFrameKey = target.key
                current = target
                video = target.video
                cinema = true
                status = ""
            } else if now > request.expiration {
                pendingCinema = nil
                status = "Cinema needs a visible video. Scroll it into view and try again."
                onCinemaNotice?(status)
            }
        }
    }

    private func projectedBox(_ source: Source) -> CGRect? {
        let box = source.video.box
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        if source.video.mainFrame {
            return box.intersection(unit)
        }
        guard let parent = embeddedRects[source.key]?.box else {
            return nil
        }
        return CGRect(
            x: parent.minX + box.minX * parent.width, y: parent.minY + box.minY * parent.height,
            width: box.width * parent.width, height: box.height * parent.height
        )
        .intersection(parent).intersection(unit)
    }

    func isOverPlayingVideo(at point: CGPoint) -> Bool {
        guard let source = current, !source.video.paused else {
            return false
        }
        if let mapping {
            return mapping.destination.contains(point)
        }
        guard let box = projectedBox(source), !box.isNull else {
            return false
        }
        return box.contains(CGPoint(x: point.x / 1000, y: point.y / 625))
    }

    var mapping: CinemaMapping? {
        guard cinema, canUseCinema(), let current, let box = projectedBox(current), !box.isNull else {
            return nil
        }
        let video = current.video
        let full = CGRect(x: box.minX * 1000, y: box.minY * 625, width: box.width * 1000, height: box.height * 625)
        guard full.width > 15, full.height > 15 else {
            return nil
        }
        // Typical video elements use contain; use the intrinsic shape to avoid enlarging letterbox bars.
        var crop = full
        if video.aspect > 0 {
            if full.width / full.height > video.aspect {
                crop = full.insetBy(dx: (full.width - full.height * video.aspect) / 2, dy: 0)
            } else {
                crop = full.insetBy(dx: 0, dy: (full.height - full.width / video.aspect) / 2)
            }
        }
        return CinemaMapping(crop: crop)
    }

    func setCinema(_ enabled: Bool) {
        if enabled {
            requestCinema(nil)
        } else {
            pendingCinema = nil
            cinemaFrameKey = nil
            cinema = false
            status = ""
        }
    }

    private func requestCinema(_ key: String?) {
        guard canUseCinema() else {
            return
        }
        pendingCinema = (key, CACurrentMediaTime() + 1.1)
        refresh()
    }

    func command(_ op: String, value: Double = 0, completion: ((Bool) -> Void)? = nil) {
        guard let current, let web else {
            completion?(false)
            return
        }
        let request = generation
        web.callAsyncJavaScript(
            "return await globalThis.vxrMediaCommand(id,op,value);",
            arguments: ["id": current.video.id, "op": op, "value": value],
            in: current.frame, in: world
        ) { [weak self] result in
            guard let self, self.generation == request else {
                completion?(false)
                return
            }
            if case .success(let value) = result, value as? Bool == true {
                completion?(true)
                return
            }
            completion?(false)
            guard op != "muteAndPlay" else {
                return
            }
            self.status = "That playback control is unavailable. Try the control on the page."
            if op == "seek" {
                self.seekFailed = true
            }
        }
    }

    func setMuted(_ muted: Bool, completion: ((Bool) -> Void)? = nil) {
        guard muted else {
            command("unmute", completion: completion)
            return
        }
        guard let web else {
            completion?(false)
            return
        }
        let frames = reportingFrames
        let generation = generation
        // Main-frame fallback also covers a page whose video disappeared before it reported.
        var requests: [WKFrameInfo?] = frames.filter { $0.key != "main" }.map { $0.value.0 }
        requests.append(nil)
        var remaining = requests.count
        var selectedMuted = false
        let selectedKey = current?.key ?? "main"
        for frame in requests {
            let isSelected = frame.map { view in frames[selectedKey]?.0 === view } ?? (selectedKey == "main")
            web.callAsyncJavaScript(
                "return globalThis.vxrPanelMute?.() ?? false;", arguments: [:], in: frame, in: world
            ) { [weak self] result in
                if isSelected, case .success(let value) = result, value as? Bool == true {
                    selectedMuted = true
                }
                remaining -= 1
                if remaining == 0 {
                    completion?(self?.generation == generation && selectedMuted)
                }
            }
        }
    }

    func trace(_ event: String, time: Double = Date().timeIntervalSince1970) {
        playbackTrace.append((time, event))
        if playbackTrace.count > 60 {
            playbackTrace.removeFirst(playbackTrace.count - 60)
        }
    }

    func exitVideoPresentation() {
        presentationGate.dismiss(at: CACurrentMediaTime())
        setCinema(false)
        exitNativeFullscreen(enterCinema: false, forced: true)
    }

    func exitNativeFullscreen(enterCinema: Bool = false, forced: Bool = false) {
        guard let web, forced || !closingPresentation else {
            return
        }
        let revision = presentationGate.revision
        let openCinema = enterCinema && presentationGate.accepts(at: CACurrentMediaTime(), revision: revision)
        let id = UUID()
        closeID = id
        closingPresentation = true
        let exitScript = """
            document.querySelectorAll('video').forEach(v => {
                try {
                    if (v.webkitDisplayingFullscreen) {
                        v.webkitExitFullscreen?.();
                    }
                    if (v.webkitPresentationMode === 'fullscreen') {
                        v.webkitSetPresentationMode?.('inline');
                    }
                } catch {}
            });
            if (document.fullscreenElement) {
                document.exitFullscreen?.().catch(()=>{});
            } else if (document.webkitFullscreenElement) {
                document.webkitExitFullscreen?.();
            }
            """
        if forced || nativeFullscreen || web.fullscreenState != .notInFullscreen {
            for frame in reportingFrames.values.map(\.0) where !frame.isMainFrame {
                web.callAsyncJavaScript(exitScript, arguments: [:], in: frame, in: .page, completionHandler: nil)
            }
            web.evaluateJavaScript(exitScript, completionHandler: nil)
        }
        web.closeAllMediaPresentations { [weak self, weak web] in
            guard let self, self.closeID == id else {
                return
            }
            self.closingPresentation = false
            self.nativeFullscreen = (web?.fullscreenState ?? .notInFullscreen) != .notInFullscreen
            if openCinema && self.presentationGate.accepts(at: CACurrentMediaTime(), revision: revision) {
                self.setCinema(true)
            }
            self.onRecovery?()
        }
    }

    /// Messages from the media script running in every frame of the page.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web else {
            return
        }
        if message.name == "vxrCinema" {
            scheduleCinemaFallback()
            return
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            return
        }
        if kind == "presentation" {
            handlePresentation(body)
            return
        }
        let frame = message.frameInfo
        guard let frameID = body["frameID"] as? String, frameID.count < 80 else {
            return
        }
        let key = frame.isMainFrame ? "main" : frameID
        // Ignore main-frame reports sent before a navigation to another site finished.
        if frame.isMainFrame, let sender = frame.request.url, let url = web?.url,
            sender.scheme != url.scheme || sender.host != url.host
        {
            return
        }
        reportingFrames[key] = (frame, CACurrentMediaTime())
        switch kind {
        case "frameGeometry":
            handleFrameGeometry(body, from: frame)
        case "cinemaRequest", "cinemaExit":
            handleCinemaSignal(kind, frameKey: key)
        case "playback":
            handlePlayback(body, frameKey: key)
        case "empty":
            sources[key] = nil
            refresh()
        case "video":
            handleVideoReport(body, frameKey: key, frame: frame)
        default:
            break
        }
    }

    // The page asked for cinema without saying which video. Wait briefly for a
    // frame-specific request, and fall back to the selected video if none arrives.
    private func scheduleCinemaFallback() {
        let fallbackAt = CACurrentMediaTime()
        let token = generation
        let revision = presentationGate.revision
        guard presentationGate.accepts(at: fallbackAt) else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, self.generation == token,
                self.presentationGate.accepts(at: CACurrentMediaTime(), revision: revision),
                !self.cinema, self.pendingCinema == nil, self.lastFrameCinemaSignal < fallbackAt - 0.18
            else {
                return
            }
            self.requestCinema(nil)
        }
    }

    // The page entered or left its own full screen. Turn native full screen into cinema.
    private func handlePresentation(_ body: [String: Any]) {
        let native = body["native"] as? Bool == true
        let element = body["element"] as? Bool == true
        let mode = (body["mode"] as? String).map { String($0.prefix(30)) } ?? ""
        note("Presentation event: native=\(native), element=\(element), mode=\(mode)")
        if native || element || mode == "fullscreen" {
            nativeFullscreen = true
            exitNativeFullscreen(enterCinema: true)
        } else {
            nativeFullscreen = (web?.fullscreenState ?? .notInFullscreen) != .notInFullscreen
        }
    }

    // Where a child frame sits inside the main page, as fractions of the page.
    private func handleFrameGeometry(_ body: [String: Any], from frame: WKFrameInfo) {
        guard frame.isMainFrame, let child = body["child"] as? String, child.count < 80,
            sources[child] != nil || reportingFrames[child] != nil,
            let box = body["box"] as? [Double], box.count == 4,
            box.allSatisfy({ $0.isFinite && abs($0) < 50 }), box[2] > 0, box[3] > 0
        else {
            return
        }
        embeddedRects[child] = (CGRect(x: box[0], y: box[1], width: box[2], height: box[3]), CACurrentMediaTime())
        refresh()
    }

    private func handleCinemaSignal(_ kind: String, frameKey key: String) {
        let now = CACurrentMediaTime()
        lastFrameCinemaSignal = now
        if kind == "cinemaExit" {
            if cinemaFrameKey == key || pendingCinema?.key == key || (cinema && current?.key == key) {
                presentationGate.dismiss(at: now)
                setCinema(false)
            }
            return
        }
        // Ignore repeated requests within half a second.
        guard presentationGate.accepts(at: now), now - lastCinemaRequest > 0.5 else {
            return
        }
        lastCinemaRequest = now
        if cinema, cinemaFrameKey == key {
            presentationGate.dismiss(at: now)
            setCinema(false)
        } else {
            requestCinema(key)
        }
    }

    // Play, pause and volume events. Only the selected video decides who owns the audio.
    private func handlePlayback(_ body: [String: Any], frameKey key: String) {
        guard let event = body["event"] as? String,
            ["play", "playing", "pause", "waiting", "volumechange", "visibilitychange"].contains(event),
            let paused = body["paused"] as? Bool, let muted = body["muted"] as? Bool,
            let id = body["id"] as? Int
        else {
            return
        }
        let visible = body["visible"] as? String == "visible"
        let requested = body["requested"] as? Bool == true
        let ready = body["ready"] as? Int ?? 0
        let timestamp = (body["at"] as? Double ?? Date().timeIntervalSince1970 * 1000) / 1000
        var pauseSource = ""
        if event == "pause" {
            pauseSource = requested ? ", requested" : ", unrequested"
        }
        let state = "\(paused ? "paused" : "playing"), \(muted ? "muted" : "audible")"
        trace(
            "\(event), \(state), ready=\(ready), \(visible ? "visible" : "hidden")\(pauseSource)",
            time: timestamp)
        guard body["selected"] as? Bool == true,
            current?.key == key, current?.video.id == id
        else {
            return
        }
        if event == "playing" || event == "volumechange" || event == "pause" {
            if !paused && !muted {
                onAudioEvent?(true)
            } else if muted || paused {
                onAudioEvent?(false)
            }
        }
    }

    // Position, time and state of the largest video in a frame.
    private func handleVideoReport(_ body: [String: Any], frameKey key: String, frame: WKFrameInfo) {
        guard let id = body["id"] as? Int, let boxValues = body["box"] as? [Double], boxValues.count == 4,
            boxValues.allSatisfy({ $0.isFinite && abs($0) < 100 }),
            let time = body["time"] as? Double, time.isFinite,
            let duration = body["duration"] as? Double, duration.isFinite
        else {
            return
        }
        let seekable = body["seekable"] as? [Double] ?? []
        var range: ClosedRange<Double>?
        if seekable.count == 2 && seekable.allSatisfy(\.isFinite) && seekable[0] < seekable[1] {
            range = seekable[0]...seekable[1]
        }
        let video = Video(
            id: id, box: CGRect(x: boxValues[0], y: boxValues[1], width: boxValues[2], height: boxValues[3]),
            time: time, duration: duration,
            paused: body["paused"] as? Bool ?? true, muted: body["muted"] as? Bool ?? false,
            range: range, mainFrame: frame.isMainFrame, aspect: body["aspect"] as? Double ?? 0)
        sources[key] = Source(key: key, frame: frame, video: video, updated: CACurrentMediaTime())
        refresh()
    }

    private func note(_ event: String) {
        let windows = web?.window?.windowScene?.windows.map { String(describing: type(of: $0)) } ?? []
        let parent = web?.superview.map { String(describing: type(of: $0)) } ?? "detached"
        diagnostics.append("\(event); windows=\(windows); source parent=\(parent)")
        diagnostics = Array(diagnostics.suffix(16))
    }
}
/// Forwards script messages without WebKit keeping the handler alive.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var handler: WKScriptMessageHandler?
    init(_ handler: WKScriptMessageHandler) {
        self.handler = handler
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handler?.userContentController(controller, didReceive: message)
    }
}
private extension CGSize {
    var area: CGFloat { width.isFinite && height.isFinite ? max(0, width) * max(0, height) : 0 }
}
