import AdapterTracking
import Combine
import Foundation
import QuartzCore
import SpatialMath
import UIKit
import WebKit
import simd

// Where the workspace sits in the room: placement, Recenter and drift logging.
extension BrowserScreen {
    var placementHint: String {
        switch workspace.placement.phase {
        case .waiting:
            return "Waiting for head tracking"
        case .settling:
            return "Centering… look where you want the screen"
        case .placed:
            return ""
        }
    }

    var panelAnchor: simd_quatf {
        offset.anchor(in: workspace.placement.anchor)
    }

    var trackingNotice: String {
        if workspace.trackingPaused {
            return workspace.pendingRecenter?.announcedWaiting == true
                ? "Tracking paused · Recenter queued" : "Tracking paused"
        }
        if workspace.pendingRecenter?.announcedWaiting == true {
            return "Recenter waiting for tracking…"
        }
        return workspace.initialSetup ? "Setting up tracking… hold still" : ""
    }

    func centerPanelNow() {
        if self !== owner {
            owner.centerPanelNow()
            return
        }
        requestRecenter(delay: 0, reason: "Manual")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func schedulePanelCenter() {
        if self !== owner {
            owner.schedulePanelCenter()
            return
        }
        requestRecenter(delay: 3, reason: "Countdown")
        workspace.centerCountdown = 3
        workspace.centerMessage = "Look where you want the screen."
    }

    func requestRecenter(delay: CFTimeInterval, reason: String) {
        guard !fullScreenRouting else {
            return
        }
        let now = CACurrentMediaTime()
        recordDriftEvent("Recenter requested: " + reason, at: now)
        workspace.pendingRecenter = RecenterRequest(dueAt: now + delay)
    }

    func restartTracking() {
        if self !== owner {
            owner.restartTracking()
            return
        }
        if workspace.pendingRecenter != nil {
            recordDriftEvent("Recenter canceled: manual tracking restart")
        }
        workspace.pendingRecenter = nil
        workspace.centerCountdown = 0
        workspace.centerMessage = ""
        selectedSession.showNotice("Restarting tracking…")
        GlassesDisplay.shared.tracking.restartTracking()
    }

    func recordDriftEvent(_ event: String, at now: CFTimeInterval = CACurrentMediaTime()) {
        workspace.drift.event(event, at: now)
    }

    func resetPanelAnchor(reason: String = "Workspace reset", keepRecenter: Bool = false) {
        // Opening or closing another screen must not move the workspace.
        guard self === owner else {
            return
        }
        recordDriftEvent(reason)
        workspace.drift.markAnchorChange()
        if workspace.placement.isFollowing {
            recordDriftEvent("Follow finished (reset)")
        }
        workspace.placement.waitForTracking()
        workspace.poseRecoveryPending = false
        workspace.lastAimedPlacement = -1
        if !keepRecenter {
            if workspace.pendingRecenter != nil {
                recordDriftEvent("Recenter canceled: " + reason)
            }
            workspace.pendingRecenter = nil
            workspace.centerCountdown = 0
            workspace.centerMessage = ""
        }
    }

    func aimPhoneNow() {
        if self !== owner {
            owner.aimPhoneNow()
            return
        }
        guard workspace.input == .remote, workspace.placement.phase != .waiting else {
            return
        }
        if GlassesDisplay.shared.phone.calibrateSpatial(target: selectedSession.panelAnchor) {
            workspace.lastAimedPlacement = workspace.placement.placementID
            workspace.aimedPanel = selectedPanel
        }
    }

    func recordAppActivity(active: Bool) {
        let now = CACurrentMediaTime()
        if !active {
            if workspace.inactiveSince == nil {
                workspace.inactiveSince = now
            }
        } else if let start = workspace.inactiveSince {
            workspace.recentInactivePeriods.append(start...now)
            if workspace.recentInactivePeriods.count > 12 {
                workspace.recentInactivePeriods.removeFirst()
            }
            workspace.inactiveSince = nil
        }
        recordDriftEvent(active ? "App active" : "App inactive", at: now)
    }

    func recordPoseGap(_ gap: PoseGap, canRecover: Bool) {
        let device = gap.deviceInterval.map { String(format: "%.3f", $0) } ?? "counter reset"
        recordDriftEvent(
            """
            Packet gap: arrival \(String(format:"%.3f",gap.arrivalInterval)) s, device \(device), connection \
            \(gap.connection)
            """,
            at: gap.receivedAt)
        guard canRecover, gap.warrantsPlacementRecovery, workspace.placement.phase == .placed else {
            return
        }
        let interval = (gap.receivedAt - gap.arrivalInterval)...gap.receivedAt
        // Suspension can skip delivery while the adapter keeps streaming. Preserve
        // placement for an ambiguous same-connection gap spanning app inactivity.
        if workspace.inactiveSince.map({ $0 <= interval.upperBound }) == true
            || workspace.recentInactivePeriods.contains(where: { $0.overlaps(interval) })
        {
            recordDriftEvent("Kept anchor: packet gap overlapped app inactivity")
            return
        }
        if workspace.placement.isFollowing {
            recordDriftEvent("Follow finished (packet gap)")
        }
        workspace.placement.waitForTracking()
        workspace.drift.markAnchorChange()
        workspace.poseRecoveryPending = true
        recordDriftEvent("Gap recovery started")
    }

    func panelRelativeFrame(_ frame: RenderFrame, now: CFTimeInterval) -> RenderFrame {
        workspace.lastWorldCamera = frame.orientation
        workspace.lastFrameLive = frame.live
        let frozen = native.freezePanel
        let poseInput = GlassesDisplay.shared.browserPoseFrame
        let unchanged = poseInput.unchangedAfterGap(at: now)
        if frame.live {
            workspace.hadLiveTracking = true
        }
        workspace.trackingPaused = (workspace.hadLiveTracking && !frame.live) || unchanged
        let firstConnectionPlacement = poseInput.sample.map { $0.connection != workspace.lastPlacedConnection } ?? false
        workspace.initialSetup = frame.live && firstConnectionPlacement && workspace.placement.phase != .placed
        let force = stepPendingRecenter(
            frame: frame, frozen: frozen, poseInput: poseInput, unchanged: unchanged, now: now)
        if !frozen {
            updatePlacement(
                frame: frame, force: force, firstConnectionPlacement: firstConnectionPlacement, unchanged: unchanged,
                poseInput: poseInput, now: now)
        }
        if frame.live, !frozen, workspace.input == .remote, workspace.placement.phase == .placed,
            force || workspace.lastAimedPlacement != workspace.placement.placementID
                || workspace.aimedPanel != selectedPanel
                || !GlassesDisplay.shared.phone.aimReady
        {
            let phone = GlassesDisplay.shared.phone
            if force || phone.settledForSpatialAim {
                aimPhoneNow()
            }
        }
        var local = frame
        local.orientation = frozen ? SceneMath.identity : workspace.placement.relativeCamera(frame.orientation)
        return local
    }

    /// Advances a scheduled Recenter. Returns true when this frame should force a new placement.
    private func stepPendingRecenter(
        frame: RenderFrame, frozen: Bool, poseInput: BrowserPoseFrame, unchanged: Bool, now: CFTimeInterval
    ) -> Bool {
        guard var request = workspace.pendingRecenter else {
            return false
        }
        var force = false
        let remaining = max(0, Int(ceil(request.dueAt - now)))
        if remaining != workspace.centerCountdown {
            workspace.centerCountdown = remaining
        }
        let action = request.step(
            now: now, live: frame.live && !frozen, arrival: poseInput.sample?.arrivalTime,
            resume: poseInput.resumption?.receivedAt, unchanged: unchanged)
        switch action {
        case .countdown:
            break
        case .pending:
            if !request.announcedWaiting {
                request.announcedWaiting = true
                workspace.centerMessage = "Recenter waiting for tracking…"
                recordDriftEvent("Recenter pending", at: now)
            }
        case .apply:
            force = true
            workspace.centerMessage = "Screen centered."
            if request.waitedForUnchanged, poseInput.acceptOnUnchangedOrientation(at: now) {
                recordDriftEvent("Recenter applied on unchanged orientation (3 s after packets resumed)", at: now)
            }
        case .expire:
            workspace.centerMessage = "Tracking did not return. Try Recenter again."
            selectedSession.showNotice(workspace.centerMessage)
            recordDriftEvent("Recenter expired", at: now)
        }
        // Applied or expired requests are finished. Others wait for a later frame.
        if action == .apply || action == .expire {
            workspace.pendingRecenter = nil
        } else {
            workspace.pendingRecenter = request
        }
        return force
    }

    // Places or follows the workspace, and logs placement changes for the drift report.
    private func updatePlacement(
        frame: RenderFrame, force: Bool, firstConnectionPlacement: Bool, unchanged: Bool,
        poseInput: BrowserPoseFrame, now: CFTimeInterval
    ) {
        let before = workspace.placement.anchor
        let placementBefore = workspace.placement.placementID
        let wasFollowing = workspace.placement.isFollowing
        workspace.placement.update(
            camera: frame.orientation, live: frame.live && !(firstConnectionPlacement && unchanged),
            speed: frame.angularSpeed, now: now,
            mode: workspace.anchorMode, force: force, followZone: Float(workspace.followDeadZone),
            followSpeed: Float(workspace.followSpeed),
            firstPlacementOnConnection: firstConnectionPlacement)
        if workspace.placement.phase == .placed, let sample = poseInput.sample {
            workspace.lastPlacedConnection = sample.connection
            workspace.initialSetup = false
        }
        if force, let sample = GlassesDisplay.shared.browserPoseFrame.sample {
            let forward = selectedSession.panelAnchor.act(SIMD3<Float>(0, 0, -1))
            workspace.drift.recenter(
                at: now, sample: sample, elevation: asin(min(1, max(-1, forward.y))) * 180 / .pi,
                before: before, after: workspace.placement.anchor, placement: workspace.placement.placementID)
        } else if placementBefore != workspace.placement.placementID
            || simd_length(before.vector - workspace.placement.anchor.vector) > 0.000001
        {
            workspace.drift.markAnchorChange()
            if placementBefore != workspace.placement.placementID {
                recordDriftEvent("Placed workspace \(workspace.placement.placementID)", at: now)
            }
        }
        if wasFollowing != workspace.placement.isFollowing {
            recordDriftEvent(workspace.placement.isFollowing ? "Follow started" : "Follow finished", at: now)
        }
        if workspace.poseRecoveryPending, workspace.placement.phase == .placed {
            workspace.poseRecoveryPending = false
            recordDriftEvent("Gap recovery placed workspace", at: now)
            selectedSession.showNotice("Workspace recentered after tracking returned.")
        }
    }

    func recordDriftFrame(
        _ frame: RenderFrame, applied: simd_float4x4?, viewport: SIMD2<Float>,
        reportable: Bool, now: CFTimeInterval
    ) {
        guard workspace.drift.needsRow(at: now) else {
            return
        }
        let pose = GlassesDisplay.shared.browserPoseFrame
        let panel = selectedSession
        var expected: simd_float4x4?
        if reportable, frame.live, !native.freezePanel, let camera = pose.camera(settings: frame.settings) {
            let workspaceCamera = workspace.placement.relativeCamera(camera)
            expected = WebPanelMath.screenTransform(
                camera: panel.offset.camera(workspaceCamera), eyeOffset: 0,
                viewport: viewport, settings: frame.settings)
        }
        workspace.drift.row(
            at: now, pose: pose, live: frame.live, anchor: workspace.placement.anchor,
            placement: workspace.placement.placementID,
            phase: workspace.placement.phase, mode: workspace.anchorMode, prediction: frame.settings.predictionEnabled,
            panel: panel.panelNumber,
            receiveCount: GlassesDisplay.shared.tracking.poses.receiveCount(at: now),
            applied: reportable ? applied : nil, expected: expected)
    }
}
