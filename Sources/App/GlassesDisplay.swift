import AdapterTracking
import Combine
import SwiftUI
import MetalKit
import SpatialMath
import simd
import UIKit

/// The latest head pose for the browser, plus what is needed to spot stale tracking.
struct BrowserPoseFrame {
    var sample: TimedPose?
    var heading: simd_quatf?
    var targetTime: CFTimeInterval = 0
    var resumption: PoseResumption?

    func unchangedAfterGap(at now: CFTimeInterval) -> Bool {
        guard let sample, let resumption, sample.connection == resumption.connection,
            resumption.orientationChangedAt == nil
        else {
            return false
        }
        return now - resumption.receivedAt < 3
    }

    func acceptOnUnchangedOrientation(at now: CFTimeInterval) -> Bool {
        guard let sample, let resumption, sample.connection == resumption.connection,
            resumption.orientationChangedAt == nil
        else {
            return false
        }
        return (3...6).contains(now - resumption.receivedAt)
    }

    func camera(settings: SceneSettings) -> simd_quatf? {
        guard let sample, let heading else {
            return nil
        }
        let orientation =
            settings.predictionEnabled
            ? sample.orientation(at: targetTime, extraPrediction: settings.extraPredictionMilliseconds / 1000)
            : sample.pose.orientation
        return SceneMath.cameraOrientation(raw: orientation, settings: settings, headingReference: heading)
    }
}

/// Shared state for the glasses: display, head tracking, scene settings and the media player.
final class GlassesDisplay: ObservableObject {
    static let shared = GlassesDisplay()
    let tracking = AdapterTracking()
    let phone = PhoneRemote()
    @Published var showDemoPanel = true
    @Published private(set) var panel = DemoPanel()
    @Published private(set) var aimCountdown = 0
    @Published private(set) var interactionMessage = "Aim at a row, then tap the phone screen."
    private var aimToken = UUID()

    func schedulePhoneAim() {
        guard aimCountdown == 0 else {
            return
        }
        phone.start()
        let token = UUID()
        aimToken = token
        aimCountdown = 3
        for second in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(second)) { [weak self] in
                guard let self, self.aimToken == token else {
                    return
                }
                self.aimCountdown = 3 - second
                if second == 3 {
                    guard let head = self.tracking.poses.snapshot(), CACurrentMediaTime() - head.arrivalTime < 0.25
                    else {
                        self.interactionMessage = "Connect head tracking before aiming the phone."
                        return
                    }
                    if self.phone.calibrate(camera: self.lastCamera) {
                        self.interactionMessage = "Phone aimed. Tap to select."
                    }
                }
            }
        }
    }

    private func interactionRay() -> PointerRay? {
        guard showDemoPanel, let head = tracking.poses.snapshot(), CACurrentMediaTime() - head.arrivalTime < 0.25 else {
            return nil
        }
        return phone.ray().flatMap { PointerRay(direction: demoPanelAnchor.inverse.act($0.direction)) }
    }

    func selectPanel() {
        guard let row = panel.select(interactionRay()) else {
            interactionMessage = "Aim the phone's top edge at a row, then tap."
            return
        }
        interactionMessage = "Selected row \(row + 1) · count \(panel.counts[row])"
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @Published private(set) var status = "Waiting for an external-display scene"
    @Published private(set) var details = ""
    @Published private(set) var inventory = ""
    @Published private(set) var events = [String]()
    @Published private(set) var measuredHz = 0.0
    @Published private(set) var poseAgeMilliseconds: Double?
    @Published private(set) var savedNormal = ""
    @Published private(set) var savedStereo = ""
    @Published var splitPattern = false
    @Published var showTrackedScene = true
    private static let sceneSettingsKey =
        (Bundle.main.bundleIdentifier ?? "io.github.koksalberkay.halopane") + ".sceneSettings.v3"

    @Published var settings: SceneSettings = {
        guard let data = UserDefaults.standard.data(forKey: GlassesDisplay.sceneSettingsKey),
            let value = try? JSONDecoder().decode(SceneSettings.self, from: data)
        else {
            return SceneSettings()
        }
        return value
    }()
    {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: GlassesDisplay.sceneSettingsKey)
            }
        }
    }
    @Published private(set) var renderStatus = "Waiting for pose"
    @Published private(set) var renderDetails = ""
    @Published private(set) var calibrationMessage =
        "Table reference is optional. It estimates tilt from how the frames rest."
    @Published private(set) var axisReference: simd_quatf?
    private var headingReference: simd_quatf?
    private var demoPanelAnchor = SceneMath.identity
    private var lastCamera = SceneMath.identity
    private var renderConnection: Int?

    func clearTable() {
        settings.clearTable()
        BrowserScreen.shared.resetPanelAnchor()
        headingReference = nil
        demoPanelAnchor = SceneMath.identity
        phone.clearAim()
        calibrationMessage = "Table correction cleared."
    }

    private var gapCursor = 0
    private var bluetoothTraceCursor = 0
    private(set) var browserPoseFrame = BrowserPoseFrame()

    func makeRenderFrame(_ link: CADisplayLink, stereo: Bool) -> RenderFrame {
        let now = CACurrentMediaTime()
        let received = tracking.poses.snapshot(afterGap: gapCursor, afterEvent: bluetoothTraceCursor)
        let sample = received.sample
        let fresh = sample.map { now - $0.arrivalTime < 0.25 } ?? false

        if fresh, let sample, sample.connection != renderConnection {
            let original = renderConnection
            BrowserScreen.shared.recordDriftEvent(
                original == nil
                    ? "First Bluetooth pose, connection \(sample.connection)"
                    : "Bluetooth reconnect \(original ?? 0) → \(sample.connection)", at: sample.arrivalTime)
            if original != nil {
                BrowserScreen.shared.resetPanelAnchor(reason: "Bluetooth reconnect", keepRecenter: true)
                nativeMedia.recenter()
            }
            renderConnection = sample.connection
            phone.clearAim()
            panel.endScroll()
            axisReference = nil
            headingReference = nil
            demoPanelAnchor = SceneMath.identity
        }
        for gap in received.gaps {
            gapCursor = gap.sequence
            let currentConnection = fresh && sample?.connection == gap.connection && renderConnection == gap.connection
            BrowserScreen.shared.recordPoseGap(gap, canRecover: currentConnection)
        }
        for event in received.events {
            bluetoothTraceCursor = event.sequence
            BrowserScreen.shared.recordDriftEvent(event.message, at: event.time)
        }
        browserPoseFrame = BrowserPoseFrame(
            sample: sample, heading: headingReference, targetTime: link.targetTimestamp, resumption: received.resumption
        )
        if let sample, fresh {
            if headingReference == nil {
                let raw =
                    settings.predictionEnabled
                    ? sample.orientation(
                        at: link.targetTimestamp, extraPrediction: settings.extraPredictionMilliseconds / 1000)
                    : sample.pose.orientation
                headingReference = SceneMath.heading(settings.bodyOrientation(raw))
                browserPoseFrame.heading = headingReference
            }
            if let camera = browserPoseFrame.camera(settings: settings) {
                lastCamera = camera
            }
        }
        return RenderFrame(
            orientation: lastCamera, settings: settings, stereo: stereo, live: fresh,
            interaction: showDemoPanel ? InteractionFrame(panel: panel, ray: interactionRay()) : nil,
            panelAnchor: demoPanelAnchor, angularSpeed: sample.map { simd_length($0.angularVelocity) } ?? 0)
    }

    func updateRenderReport(_ renderer: WorldRenderer?, size: CGSize, stereo: Bool, live: Bool) {
        renderStatus = live ? "Live pose → world-fixed scene" : "Pose unavailable or stale; view held"
        renderDetails = """
            Layout: \(stereo ? "Stereo, parallel cameras" : "Mono")
            Metal surface: \(Int(size.width)) × \(Int(size.height))
            GPU submissions: \(renderer?.submittedFrames ?? 0), skipped: \(renderer?.skippedFrames ?? 0)
            \(renderer?.error.map { "Metal error: " + $0 } ?? "")
            """
    }

    var sceneReport: String {
        let offset = SceneMath.axisAngle(settings.mountingOffset)
        var result = """
            \(renderStatus)
            \(renderDetails)
            View: \(showTrackedScene ? "Tracked scene" : "Display pattern")
            Per-eye horizontal / vertical FOV: \(settings.horizontalFOV) / \(settings.verticalFOV) degrees
            Eye separation: \(settings.eyeSeparationMillimeters) mm
            Prediction enabled: \(settings.predictionEnabled), extra: \(settings.extraPredictionMilliseconds) ms
            Quaternion inverted: \(settings.invertQuaternion)
            Table reference: \(settings.tableDate ?? "Not set")
            Body-side table correction: \(offset.degrees) degrees, axis \(offset.axis)
            Basis: adapter +X -> render -Z; +Y -> -X; +Z -> +Y (provisional physical interpretation)
            """
        result += "\n" + phone.report
        result += "\nPanel scroll offset: \(panel.scrollOffset), selection counts: \(panel.counts)"
        if let reference = axisReference, let current = tracking.measurement?.pose.orientation {
            let body = SceneMath.axisAngle(reference.inverse * current)
            let world = SceneMath.axisAngle(current * reference.inverse)
            result += "\nRaw body delta: \(body.degrees) degrees, axis \(body.axis)"
            result += "\nRaw world delta: \(world.degrees) degrees, axis \(world.axis)"
        }
        return result
    }
    @Published private(set) var hasExternalDisplay = false
    let nativeMedia = NativeMediaSession()
    @Published var nativeMediaRendererUnavailable = false
    @Published private(set) var externalStereo = false
    private weak var externalScene: UIWindowScene?
    private var available: Bool?
    private var frames = 0
    private var frameStart: CFTimeInterval?

    func event(_ text: String) {
        events.append(text)
        events = Array(events.suffix(12))
    }

    func updateAvailability(_ value: Bool) {
        guard available != value else {
            return
        }
        available = value
        event("Accessory available: \(value)")
    }

    func connect(_ scene: UIWindowScene) {
        if externalScene !== scene {
            BrowserScreen.shared.recordDriftEvent("External scene attached")
        }
        externalScene = scene
        hasExternalDisplay = true
        let size = scene.screen.currentMode?.size ?? scene.coordinateSpace.bounds.size
        externalStereo = size.width / max(size.height, 1) > 2.5
        if !tracking.active {
            tracking.connect()
        }
        status = "External-display scene connected"
        frames = 0
        frameStart = nil
        refresh()
        event("External scene connected or updated")
    }

    func disconnect(_ scene: UIWindowScene) {
        guard externalScene === scene else {
            return
        }
        externalScene = nil
        BrowserScreen.shared.recordDriftEvent("External scene detached")
        hasExternalDisplay = false
        nativeMedia.pause()
        externalStereo = false
        status = "External-display scene disconnected"
        details = ""
        measuredHz = 0
        refreshInventory()
        event("External scene disconnected")
    }

    func refreshInventory() {
        inventory = UIScreen.screens.enumerated().map { index, screen in
            "Screen \(index): \(size(screen.currentMode?.size ?? .zero)), max \(screen.maximumFramesPerSecond) Hz"
        }.joined(separator: "\n")
    }

    func refresh() {
        refreshInventory()
        guard let screen = externalScene?.screen else {
            return
        }
        let modes = screen.availableModes.map { size($0.size) }.joined(separator: ", ")
        details = """
            Current mode: \(size(screen.currentMode?.size ?? .zero)) pixels
            Preferred mode: \(size(screen.preferredMode?.size ?? .zero)) pixels
            Native bounds: \(size(screen.nativeBounds.size))
            Window bounds: \(size(externalScene?.coordinateSpace.bounds.size ?? .zero)) points
            Scale: \(screen.scale), native scale: \(screen.nativeScale)
            Maximum refresh: \(screen.maximumFramesPerSecond) Hz
            Available modes: \(modes)
            """
    }

    func tick(_ link: CADisplayLink) {
        let arrivalAge = tracking.poses.snapshot().map { (CACurrentMediaTime() - $0.arrivalTime) * 1000 }
        if frameStart == nil {
            frameStart = link.timestamp
        }
        frames += 1
        if let start = frameStart, link.timestamp - start >= 1 {
            measuredHz = Double(max(0, frames - 1)) / (link.timestamp - start)
            poseAgeMilliseconds = arrivalAge
            frames = 0
            frameStart = nil
            refresh()
        }
    }

    private var trackingReport: String {
        var lines = ["Bluetooth: " + tracking.status]
        if let sample = tracking.measurement {
            let angles = AdapterPose.angles(for: sample.pose.orientation)
            lines.append(
                String(
                    format: "Receive rate: %.1f Hz, packets: %d, gap events: %d",
                    sample.receiveHz, sample.packets, sample.gapCount))
            lines.append(
                String(
                    format: "Yaw/pitch/roll: %+.2f / %+.2f / %+.2f degrees",
                    angles.x, angles.y, angles.z))
            lines.append(String(format: "Tracking run time: %.1f s", sample.elapsed))
        }
        if let age = poseAgeMilliseconds {
            lines.append(String(format: "Latest pose arrival age at display callback: %.1f ms", age))
        }
        return lines.joined(separator: "\n")
    }

    var report: String {
        """
        \(AppDelegate.displayNameAndVersion)
        \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)

        Normal mode
        \(savedNormal.isEmpty ? "Not saved" : savedNormal)

        Glasses side-by-side mode
        \(savedStereo.isEmpty ? "Not saved" : savedStereo)

        Scene configuration
        \(sceneReport)

        Current tracking state
        \(trackingReport)

        Current screen inventory
        \(inventory)

        Events
        \(events.joined(separator: "\n"))
        """
    }

    private func size(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }
}
