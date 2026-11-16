import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Scroll test, counters and the diagnostic report.
extension BrowserScreen {
    func setPortalStatus(_ value: String) {
        portalStatus = value
    }

    func resetCounters() {
        frameStats.lastTick = nil
        frameStats.displayTicks = 0
        frameStats.snapshotCount = 0
        frameStats.requestCount = 0
        frameStats.snapshotMilliseconds = []
        frameStats.uploadMilliseconds = []
        frameStats.nextSnapshot = 0
        frameStats.lastPoll = 0
        frameStats.displayHz = 0
        frameStats.snapshotHz = 0
        diagnostics.fixtureHistory = []
    }

    func runScrollTest() {
        guard frameStats.layoutValid else {
            status = "Use normal 2D for native; SBS for the other cases."
            return
        }
        guard backend != .portal || portalStatus.contains("created") else {
            status = "Portal unavailable; this case cannot run."
            return
        }
        epoch = UUID()
        resetCounters()
        diagnostics.samples = []
        running = true
        diagnostics.runStart = CACurrentMediaTime()
        let token = UUID()
        diagnostics.runEpoch = token
        let mode = backend
        // Scrolls the page smoothly up and down for 10 seconds. A newer run or close() stops it.
        web.evaluateJavaScript(
            """
            (() => {
                const token = Date.now();
                window.__vxrScrollToken = token;
                let start = performance.now();
                function step(t) {
                    if (window.__vxrScrollToken !== token) {
                        return;
                    }
                    let dt = t - start;
                    if (dt > 10000) {
                        window.__vxrScrollToken = null;
                        return;
                    }
                    window.scrollTo(0, 90 * (1 - Math.cos(dt / 850)));
                    requestAnimationFrame(step);
                }
                requestAnimationFrame(step);
            })()
            """, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.2) { [weak self] in
            guard let self, self.running, self.diagnostics.runEpoch == token else {
                return
            }
            self.running = false
            self.completed.append(
                """
                \(Date().ISO8601Format())\n\(mode.rawValue)\n\(self.metrics)\nPage: \
                \(self.frameStats.sourceMetrics)\n\(self.diagnostics.samples.joined(separator:"\n---\n"))
                """
            )
            self.status = "10-second run saved. Share the report to send it."
        }
    }

    func cancelRun(_ reason: String) {
        if running {
            completed.append("Interrupted run: " + reason)
        }
        running = false
        diagnostics.runEpoch = UUID()
        diagnostics.runStart = nil
        web.evaluateJavaScript("window.__vxrScrollToken=null", completionHandler: nil)
    }

    func mean(_ values: [Double]) -> String {
        values.isEmpty ? "-" : String(format: "%.2f", values.reduce(0, +) / Double(values.count))
    }

    private var headSummary: String {
        let tracking = GlassesDisplay.shared.tracking
        let sample = tracking.measurement
        let age =
            tracking.poses.snapshot().map { String(format: "%.1f ms", (CACurrentMediaTime() - $0.arrivalTime) * 1000) }
            ?? "No sample"
        return
            """
            Head: \(tracking.status), receive \(sample?.receiveHz ?? 0) Hz, gaps \(sample?.gapCount ?? 0), recovery \
            attempts \(sample?.recoveryAttempts ?? 0), arrival age \(age)
            """
    }

    private var rasterReport: String {
        let scroll = web.scrollView
        return
            """
            \(diagnostics.firstMountNote); \(diagnostics.pageRasterNote); traits=\(web.traitCollection.displayScale), \
            screen=\(web.window?.screen.scale ?? 0), bounds=\(web.bounds.size), pageZoom=\(web.pageZoom), \
            scrollZoom=\(scroll.zoomScale) [\(scroll.minimumZoomScale)…\(scroll.maximumZoomScale)]
            """
    }

    private var workspacePlaybackReport: String {
        owner.allPanels.flatMap { panel in
            panel.media.playbackTrace.map { (time: $0.time, panel: panel.panelNumber, event: $0.event) }
        }
        .sorted { $0.time < $1.time }.map {
            "\(String(format:"%.3f",$0.time)) [panel \($0.panel)] \($0.event)"
        }.joined(separator: "\n")
    }

    var report: String {
        let cloudReport = "\n" + workspaceCloudReport
        let nativeMediaReport =
            "\nNative media: " + GlassesDisplay.shared.nativeMedia.summary + "\n"
            + GlassesDisplay.shared.nativeMedia.diagnostics.report
        return """
            \(AppDelegate.displayNameAndVersion)
            Privacy: names only well-known services. No other sites, page titles, addresses, files or typed text.\(nativeMediaReport)
            \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
            Active panel: \(owner.selectedPanel)\(cloudReport)
            Panels: \(owner.visiblePanels.map { "Panel \($0.panelNumber): \($0.reportSiteLabel), \($0.phonePageActive ? "phone" : "glasses"), \($0.scroll.lastRoute)" }.joined(separator:" | "))
            \(workspace.drift.summary)
            Panel switches: \(workspace.switchLog.joined(separator:" | "))
            Workspace input: \(workspace.inputLog.joined(separator:" | "))
            Audible panel ID: \(workspace.audioOwnerID.map(String.init) ?? "none")
            Per-panel status (stable ID):
            \(owner.allPanels.map { "Panel \($0.panelNumber), slot \($0.slot), \($0.reportSiteLabel)\n\($0.metrics)\n\($0.rasterReport)\nRight-click: \($0.diagnostics.secondaryClickReport)\nScroll: \($0.scroll.lastRoute); Shorts: \($0.scroll.shortsTrace.suffix(8).joined(separator:" | "))" }.joined(separator:"\n"))
            Playback timeline (no page titles or paths):
            \(workspacePlaybackReport)
            \(workspace.contentBlocker.status)
            \(workspace.contentBlocker.localStatus)
            \(workspace.adSettings.report)
            Media presentation events: \(media.diagnostics.joined(separator:" | "))
            Shorts swipe trace (no video IDs):
            \(scroll.shortsTrace.isEmpty ? "No Shorts swipe began." : scroll.shortsTrace.joined(separator:"\n"))
            Scroll engine preference: \(workspace.scrollEngine.rawValue); last route: \(scroll.lastRoute)
            GeForce NOW scroll: \(owner.allPanels.filter { !$0.scroll.catalogScrollTrace.isEmpty }
            .map { "Panel \($0.panelNumber): \($0.scroll.catalogScrollTrace.joined(separator:" → "))" }.joined(separator:" | "))
            Backend: \(backend.rawValue)
            \(headSummary)
            Projection H/V: \(GlassesDisplay.shared.settings.horizontalFOV) / \
            \(GlassesDisplay.shared.settings.verticalFOV) degrees; IPD \
            \(GlassesDisplay.shared.settings.eyeSeparationMillimeters) mm
            Phone editor fallback active: \(phoneEditor != nil)\n        Level panel anchor quaternion: \
            \(panelAnchor.vector)\n        Input: \(workspace.input.rawValue); delivery \(native.engine.rawValue)
            Public baseline: mediaTypesRequiringUserActionForPlayback=[]; JS automatic popups disabled
            Website layout requested: \(workspace.preferDesktop ? "desktop":"recommended")
            Source site: \(reportSiteLabel)
            \(diagnostics.videoEvidence)
            Encrypted media: \(encryptedMediaStatus)
            MediaSource experiment: \(mediaSourceStatus)
            Portal: \(portalStatus)
            \(metrics)
            Page telemetry: \(frameStats.sourceMetrics)
            Recent timed fixture samples:\n\(diagnostics.fixtureHistory.joined(separator:"\n"))
            Input status: \(inputStatus)
            Source bounds: \(web.bounds), scale: \(web.contentScaleFactor), layer scale: \(web.layer.contentsScale), \
            window attached: \(web.window != nil)
            Snapshot cap: \(snapshotFPS), afterScreenUpdates: \(snapshotAfterUpdates)
            Snapshot requests / completions: \(frameStats.requestCount) / \(frameStats.snapshotCount)
            Native/portal display callback Hz does not measure compositor delivery or photons.
            Replica repeats the left-eye projection at zero disparity; it is a replication control.
            Snapshot source remains visible as a thumbnail; occlusion/offscreen behavior is not tested.
            \(native.report)
            Completed runs
            \(completed.joined(separator:"\n\n"))

            \(workspace.drift.table(at:CACurrentMediaTime()))
            """
    }
}
