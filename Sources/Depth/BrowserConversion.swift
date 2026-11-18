import CoreGraphics
import ImageIO
import QuartzCore
import UIKit
import WebKit

/// How a browser screen reads its video for depth.
///
/// It first asks the page for a small copy of the current frame. Sites that
/// serve video from another origin without CORS refuse that, so it then takes
/// small snapshots of the video's area. Protected video gives neither, and 3D
/// stops with a reason.
final class WebDepthCapture {
    enum Route: String {
        case page = "Page frames"
        case snapshot = "Snapshots"
    }

    /// Width of each captured frame. The model works at 518 by 392.
    static let frameWidth = 518
    /// Black frames in a row, with no picture seen yet, before a route is given up.
    /// About a second and a half at the video depth rate.
    static let blankLimit = 20

    private(set) var route = Route.page
    private(set) var notes: [String] = []
    var busy = false
    var blankFrames = 0
    var sawPicture = false
    var startedAt: CFTimeInterval = 0
    /// What the glasses do with converted video: "shown", or why not.
    private(set) var displayState = ""
    private var displayChangedAt: CFTimeInterval = 0
    var lastCapture: CFTimeInterval = 0
    var request = UUID()

    func reset(now: CFTimeInterval) {
        route = .page
        busy = false
        blankFrames = 0
        sawPicture = false
        displayState = ""
        displayChangedAt = now
        startedAt = now
        lastCapture = 0
        request = UUID()
    }

    func switchToSnapshots(because reason: String) {
        note("Page frames unavailable (\(reason)); using snapshots")
        route = .snapshot
        blankFrames = 0
        sawPicture = false
    }

    /// Notes each change, with the seconds since 3D was turned on.
    func setDisplayState(_ state: String) {
        guard state != displayState else {
            return
        }
        displayState = state
        displayChangedAt = CACurrentMediaTime()
        note(String(format: "%.1f s: glasses %@", displayChangedAt - startedAt, state))
    }

    /// Seconds the current display state has lasted.
    func displayStateAge(now: CFTimeInterval) -> CFTimeInterval {
        now - displayChangedAt
    }

    func note(_ text: String) {
        notes.append(text)
        if notes.count > 24 {
            notes.removeFirst()
        }
    }

    var summary: String {
        "route \(route.rawValue); " + (notes.isEmpty ? "no events" : notes.joined(separator: "; "))
    }

    /// True for a frame with no picture: black, or nearly so.
    static func isBlank(_ image: CGImage) -> Bool {
        let width = 16
        let height = 9
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn && (pixels.max() ?? 0) < 12
    }

    /// Decodes the page's `data:image/jpeg;base64,...` reply.
    static func image(fromDataURL text: String) -> CGImage? {
        guard let comma = text.firstIndex(of: ","),
            let data = Data(base64Encoded: String(text[text.index(after: comma)...])),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// One-tap 2D-to-3D for web video.
extension BrowserScreen {
    static let protectedVideoNotice = "This video is protected, so it can't be converted to 3D."

    /// The 3D button: turns conversion on, entering Full Screen and Video view
    /// as needed, or turns it off.
    func toggleConversion() {
        guard self === owner.selectedSession else {
            return
        }
        if conversion.isActive {
            conversion.stop()
            return
        }
        guard fullScreenAvailable, media.video != nil else {
            showNotice("Open a video to use 3D.")
            return
        }
        // Packed 3D and conversion share the same view; only one can be on.
        stereoPacking = nil
        stereoSwapEyes = false
        if !workspace.fullScreen {
            owner.toggleFullScreen()
        }
        if !media.cinema {
            media.setCinema(true)
        }
        depthCapture.reset(now: CACurrentMediaTime())
        conversion.start()
        if !GlassesDisplay.shared.externalStereo {
            showNotice("Switch the glasses to 3D mode.")
        }
    }

    /// The glasses' message for 3D, if any: preparing, or why it is held back.
    func conversionNotice(now: CFTimeInterval) -> String? {
        guard conversion.isActive else {
            return nil
        }
        if let failure = conversion.failure {
            return failure
        }
        let state = depthCapture.displayState
        // Short waits, such as Full Screen opening, pass without a message.
        if state != "shown", !state.isEmpty, state != "glasses in 2D mode",
            depthCapture.displayStateAge(now: now) > 1.5
        {
            return "3D is waiting: " + state + "."
        }
        if conversion.phase == .preparing {
            return "Preparing 3D…"
        }
        return nil
    }

    /// Model state and each screen's conversion, for the diagnostics report.
    var conversionReport: String {
        let estimator = conversion.estimator
        let load = estimator.loadSeconds.map { String(format: ", loaded in %.1f s", $0) } ?? ""
        let used = owner.allPanels.filter { $0.conversion.stats.estimates > 0 || $0.conversion.isActive }
        let screens = used.map { panel in
            let conversion = panel.conversion
            return "Panel \(panel.panelNumber): \(conversion.phase), \(conversion.stats.summary), "
                + panel.depthCapture.summary
        }
        let player = GlassesDisplay.shared.nativeMedia.conversion
        let playerLine = "Spatial Player: \(player.phase), \(player.stats.summary)"
        return (["model \(estimator.state)\(load)"] + screens + [playerLine]).joined(separator: " | ")
    }

    /// Stops conversion and tells the viewer why.
    func conversionUnavailable(_ message: String, detail: String) {
        depthCapture.note(detail)
        conversion.stop()
        showNotice(message)
        media.setConversionStatus(message)
    }

    /// Called every display frame. Captures a frame for depth when one is due.
    func updateDepthCapture(now: CFTimeInterval) {
        guard conversion.isActive else {
            return
        }
        // Video view can take a moment to open, so only give up after a grace period.
        guard self === owner.selectedSession, media.video != nil, media.cinema || now - depthCapture.startedAt < 2
        else {
            conversion.stop()
            return
        }
        // Black frames never reach the model, so the capture keeps its own pace too.
        guard let video = media.video, !depthCapture.busy, !(video.paused && conversion.hasDepthMap),
            now - depthCapture.lastCapture >= 1 / StereoConversion.videoRate,
            conversion.wantsFrame(now: now, still: false)
        else {
            return
        }
        depthCapture.busy = true
        depthCapture.lastCapture = now
        let request = depthCapture.request
        switch depthCapture.route {
        case .page:
            capturePageFrame(request: request)
        case .snapshot:
            captureSnapshot(request: request)
        }
    }

    // MARK: Capture routes

    private func capturePageFrame(request: UUID) {
        media.evaluateOnVideo(
            "return globalThis.vxrMediaFrame?.(id,width) ?? {error:'noScript'};",
            arguments: ["width": WebDepthCapture.frameWidth]
        ) { [weak self] reply in
            guard let self, self.depthCapture.request == request else {
                return
            }
            self.depthCapture.busy = false
            let answer = reply as? [String: Any]
            if let text = answer?["image"] as? String, let image = WebDepthCapture.image(fromDataURL: text) {
                self.useCapturedFrame(image)
                return
            }
            switch answer?["error"] as? String {
            case "protected":
                self.conversionUnavailable(Self.protectedVideoNotice, detail: "page reports encrypted media")
            case "notReady", "gone":
                break
            case let reason:
                self.depthCapture.switchToSnapshots(because: reason ?? "no reply")
            }
        }
    }

    private func captureSnapshot(request: UUID) {
        guard let crop = media.mapping?.crop else {
            depthCapture.busy = false
            return
        }
        let config = WKSnapshotConfiguration()
        config.rect = crop
        config.snapshotWidth = NSNumber(value: WebDepthCapture.frameWidth)
        config.afterScreenUpdates = false
        web.takeSnapshot(with: config) { [weak self] image, error in
            guard let self, self.depthCapture.request == request else {
                return
            }
            self.depthCapture.busy = false
            if let image = image?.cgImage {
                self.useCapturedFrame(image)
            } else if let error {
                self.depthCapture.note("Snapshot failed: " + error.localizedDescription)
            }
        }
    }

    /// Black frames with no picture seen yet mean the route cannot read this
    /// video. Snapshots are tried after page frames; if both are black, the
    /// video is protected.
    private func useCapturedFrame(_ image: CGImage) {
        guard WebDepthCapture.isBlank(image) else {
            depthCapture.sawPicture = true
            depthCapture.blankFrames = 0
            conversion.submit(image, quarterTurns: 0, now: CACurrentMediaTime())
            return
        }
        depthCapture.blankFrames += 1
        guard !depthCapture.sawPicture, depthCapture.blankFrames >= WebDepthCapture.blankLimit else {
            return
        }
        if depthCapture.route == .page {
            depthCapture.switchToSnapshots(because: "frames were black")
        } else {
            conversionUnavailable(Self.protectedVideoNotice, detail: "snapshots were black")
        }
    }
}
