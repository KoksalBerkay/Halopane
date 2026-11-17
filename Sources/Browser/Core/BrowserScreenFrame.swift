import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Per-frame work for each panel: hover, snapshots and page polling.
extension BrowserScreen {
    func tick(_ link: CADisplayLink, size: CGSize, pixels: CGSize?, frame: RenderFrame) {
        guard active else {
            return
        }
        if frameStats.surfaceSize != size {
            cancelRun("Display geometry changed")
            resetCounters()
        }
        frameStats.surfaceSize = size
        frameStats.physicalPixels = pixels ?? size
        let wide = size.width / max(size.height, 1) > 2.5
        frameStats.layoutValid = backend == .snapshot ? wide : (backend != .native || !wide)
        effectiveCursor = cursorForCurrentInput(frame)
        let now = CACurrentMediaTime()
        updateCloudController(now: now)
        if frameStats.lastTick == nil {
            frameStats.lastTick = now
        }
        frameStats.displayTicks += 1
        if backend == .snapshot {
            requestSnapshot(now: now)
        }
        updateHomeHover(now: now)
        flushNativeScroll()
        if scroll.catalogScroll {
            flushScroll()
        }
        if now - frameStats.lastPoll >= 1 {
            updateOncePerSecond(now: now, size: size)
        }
    }

    // Where the cursor is on the page for the current input mode, or nil when it is off the page.
    private func cursorForCurrentInput(_ frame: RenderFrame) -> SIMD2<Float>? {
        switch effectiveInput {
        case .gaze:
            guard frame.live else {
                return nil
            }
            let ray = PointerRay(direction: frame.orientation.act(SIMD3<Float>(0, 0, -1)))
            return ray.flatMap { WebPanelMath.point(for: $0, topInset: chromeInset) }
        case .remote:
            guard frame.live, let phoneRay = GlassesDisplay.shared.phone.spatialRay() else {
                return nil
            }
            // The phone ray is in world space; turn it into this panel's space.
            let ray = PointerRay(direction: panelAnchor.inverse.act(phoneRay.direction))
            return ray.flatMap { WebPanelMath.point(for: $0, topInset: chromeInset) }
        case .trackpad:
            return cursor
        }
    }

    // Rates for the diagnostics report, plus page and media polling.
    private func updateOncePerSecond(now: CFTimeInterval, size: CGSize) {
        frameStats.lastPoll = now
        let dt = max(0.001, now - (frameStats.lastTick ?? now))
        frameStats.displayHz = Double(max(0, frameStats.displayTicks - 1)) / dt
        frameStats.snapshotHz = Double(frameStats.snapshotCount) / dt
        metrics = """
            Actual mode: \(Int(frameStats.physicalPixels.width)) × \(Int(frameStats.physicalPixels.height)) pixels
            View bounds: \(Int(size.width)) × \(Int(size.height)) points
            Layout for selected case: \(frameStats.layoutValid ? "valid" : "switch glasses mode")
            Display callbacks: \(String(format:"%.1f",frameStats.displayHz)) Hz
            Snapshot completions: \(String(format:"%.1f",frameStats.snapshotHz)) Hz
            Snapshot pixels: \(Int(frameStats.latestImageSize.width)) × \(Int(frameStats.latestImageSize.height))
            Mean snapshot / upload: \(mean(frameStats.snapshotMilliseconds)) / \(mean(frameStats.uploadMilliseconds)) ms
            Snapshot GPU: \(frameStats.snapshotGPU)
            """
        media.refresh()
        pollPage()
        pollCloudSignals()
        if running {
            diagnostics.samples.append(metrics + "\nPage sample (asynchronously polled): " + frameStats.sourceMetrics)
        }
    }

    private func updateHomeHover(now: CFTimeInterval) {
        guard isHome, now - homeHoverAt >= 1.0 / 15 else {
            return
        }
        homeHoverAt = now
        let ads =
            !owner.adsEnabled
            ? "Ad blocking off"
            : (!installedRules.isEmpty
                ? "Ad blocking on"
                : workspace.adSettings.state.bundledEnabled ? workspace.contentBlocker.status : "No active ad lists")
        let status = "\(displayIndex)/\(owner.visiblePanels.count)/\(ads)"
        if status != homeStatus {
            homeStatus = status
            web.callAsyncJavaScript(
                "globalThis.vxrHomeStatus?.(index,total,ads);",
                arguments: ["index": displayIndex, "total": owner.visiblePanels.count, "ads": ads],
                in: nil, in: .page, completionHandler: nil)
        }
        let point = receivesInput ? effectiveCursor : nil
        if point != lastHomeCursor {
            lastHomeCursor = point
            web.callAsyncJavaScript(
                "globalThis.vxrHomeHover?.(x,y);",
                arguments: ["x": point?.x ?? -1, "y": point?.y ?? -1], in: nil, in: .page, completionHandler: nil)
        }
    }

    private func requestSnapshot(now: Double) {
        guard !frameStats.inFlight, UIApplication.shared.applicationState == .active,
            now >= frameStats.nextSnapshot
        else {
            return
        }
        let period = 1 / max(snapshotFPS, 1)
        if frameStats.nextSnapshot == 0 {
            frameStats.nextSnapshot = now
        }
        frameStats.nextSnapshot += period
        if frameStats.nextSnapshot < now {
            frameStats.nextSnapshot = now + period
        }
        frameStats.inFlight = true
        frameStats.requestCount += 1
        let token = epoch
        let start = CACurrentMediaTime()
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 1000, height: 625)
        config.snapshotWidth = 1000
        config.afterScreenUpdates = snapshotAfterUpdates
        web.takeSnapshot(with: config) { [weak self] image, error in
            guard let self else {
                return
            }
            self.frameStats.inFlight = false
            guard self.active, self.epoch == token, self.backend == .snapshot else {
                return
            }
            if let error {
                self.status = "Snapshot error: " + error.localizedDescription
                return
            }
            guard let cg = image?.cgImage else {
                self.status = "Snapshot returned no image"
                return
            }
            self.frameStats.snapshotMilliseconds.append((CACurrentMediaTime() - start) * 1000)
            self.frameStats.latestImageSize = CGSize(width: cg.width, height: cg.height)
            do {
                guard let upload = self.uploadSnapshot else {
                    self.status = "Metal surface unavailable"
                    return
                }
                self.frameStats.uploadMilliseconds.append(try upload(cg))
                self.frameStats.snapshotCount += 1
            } catch {
                self.status = "Texture upload: " + error.localizedDescription
            }
        }
    }

    // WebKit can fall back to the system appearance for a page with no
    // background. Check the document so a transparent page keeps its white canvas.
    private static let pageBackdropScript = """
        if (!document.documentElement || document.readyState === 'loading') {
            return null;
        }
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 1;
        const pixel = canvas.getContext('2d', { willReadFrequently: true });
        if (!pixel) {
            return null;
        }
        for (const element of [document.body, document.documentElement]) {
            if (!element) {
                continue;
            }
            pixel.clearRect(0, 0, 1, 1);
            pixel.fillStyle = 'transparent';
            pixel.fillStyle = getComputedStyle(element).backgroundColor;
            pixel.fillRect(0, 0, 1, 1);
            const [r, g, b, a] = pixel.getImageData(0, 0, 1, 1).data;
            if (a === 255) {
                return [r, g, b];
            }
        }
        return [255, 255, 255];
        """

    func refreshPageBackdrop() {
        // Keep the previous backing during navigation. Never apply a response
        // belonging to an older document.
        guard active, navigationFinished else {
            return
        }
        backdropQuery += 1
        let query = backdropQuery
        web.callAsyncJavaScript(Self.pageBackdropScript, arguments: [:], in: nil, in: scrollWorld) {
            [weak self] result in
            guard let self, self.active, self.navigationFinished, self.backdropQuery == query,
                let rgb = (try? result.get()) as? [Double], rgb.count == 3
            else {
                return
            }
            let color = UIColor(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1)
            if self.web.backgroundColor != color {
                self.web.backgroundColor = color
            }
        }
    }

    private func pollPage() {
        let fixture = isFixture
        let host = native.phoneHosted ? "covered phone" : "external"
        let context = epoch
        // The fixture page reports its own metrics. Other pages report title, scroll and video state.
        web.evaluateJavaScript(
            """
            JSON.stringify({
                visibility: document.visibilityState,
                dpr: devicePixelRatio,
                viewportScale: visualViewport?.scale,
                innerWidth: innerWidth,
                layoutWidth: document.documentElement.clientWidth,
                ...(window.__vxrMetrics ? window.__vxrMetrics() : {
                    scrollY: scrollY,
                    video: [...document.querySelectorAll('video')].map(v => ({
                        time: v.currentTime,
                        paused: v.paused,
                        ready: v.readyState,
                        mediaKeys: !!v.mediaKeys,
                        legacyKeys: !!v.webkitKeys,
                        presentation: v.webkitPresentationMode || 'unknown',
                        error: v.error?.code
                    }))
                })
            })
            """
        ) { [weak self] value, error in
            guard let self, self.active, self.epoch == context else {
                return
            }
            if let raw = value as? String,
                let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            {
                self.diagnostics.pageRasterNote = ["dpr", "viewportScale", "innerWidth", "layoutWidth"].map { key in
                    "\(key)=\(obj[key] ?? "-")"
                }.joined(separator: ", ")
            }
            self.frameStats.sourceMetrics = (value as? String) ?? error?.localizedDescription ?? "No page metrics"
            if fixture, self.isFixture, let value = value as? String {
                self.diagnostics.fixtureHistory.append(
                    String(format: "%.2f", CACurrentMediaTime()) + " · " + host + " · " + value)
                self.diagnostics.fixtureHistory = Array(self.diagnostics.fixtureHistory.suffix(12))
            }
        }
    }
}
