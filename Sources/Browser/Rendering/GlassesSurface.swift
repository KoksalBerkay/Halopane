import MetalKit
import QuartzCore
import SpatialMath
import UIKit
import simd

/// A view whose layer copies its content into the second eye.
final class ReplicatorHost: UIView {
    override class var layerClass: AnyClass { CAReplicatorLayer.self }
}

/// The view in the glasses that places and draws every browser screen.
final class GlassesSurface: UIView {
    let browser = BrowserScreen.shared
    private var configured: WebBackend?
    var configuredPhoneHost = false
    private var previousSize = CGSize.zero
    var left = UIView(), right = UIView(), source = UIView()
    var portal: UIView?
    var replica: ReplicatorHost?
    var metal: MTKView?
    var renderer: WebSnapshotRenderer?
    var dots = [UIView]()
    var chrome = [BrowserChromeView]()
    var lastRevision = -1
    private var workspaceRendering = false
    var mounts: [Int: PanelMount] = [:]
    let stereoVideo = StereoVideoMount()
    let edgeHint = UILabel()
    let workspaceNotice = UILabel()
    let calibration = CAShapeLayer()
    var workspacePointers: [WorkspacePointer] = []
    var lastLayerOrder = 0
    private var phoneSignInLabels: [UILabel] = []
    private var signInLayout = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    private func reset() {
        if browser.web.isDescendant(of: source) {
            browser.web.removeFromSuperview()
            browser.web.transform = .identity
        }
        subviews.forEach {
            $0.removeFromSuperview()
        }
        portal = nil
        replica = nil
        metal = nil
        renderer = nil
        dots = []
        browser.uploadSnapshot = nil
        stereoVideo.releaseVideo()
        mounts.values.forEach {
            $0.detach()
        }
        mounts.removeAll()
        workspaceRendering = false
        lastLayerOrder = 0
        edgeHint.removeFromSuperview()
        workspaceNotice.removeFromSuperview()
        calibration.removeFromSuperlayer()
        workspacePointers.removeAll()
        chrome.removeAll()
        phoneSignInLabels.removeAll()
    }
    func stop() {
        reset()
        configured = nil
    }

    private func configure() {
        reset()
        configured = browser.backend
        configuredPhoneHost = NativeInput.shared.phoneHosted
        previousSize = bounds.size
        let wide = bounds.width / max(1, bounds.height) > 2.5
        let eyeWidth = wide ? bounds.width / 2 : bounds.width
        left = UIView(frame: CGRect(x: 0, y: 0, width: eyeWidth, height: bounds.height))
        right = UIView(frame: CGRect(x: eyeWidth, y: 0, width: eyeWidth, height: bounds.height))
        left.clipsToBounds = true
        right.clipsToBounds = true
        source = UIView(frame: CGRect(x: 0, y: 0, width: 1000, height: 625))
        source.layer.anchorPoint = .zero
        source.layer.position = .zero
        workspaceRendering = browser.backend == .replica && !configuredPhoneHost
        if !configuredPhoneHost && !browser.phonePageActive && !usesWorkspace {
            browser.web.frame = source.bounds
            browser.web.contentScaleFactor = 1
            source.addSubview(browser.web)
        }
        if browser.backend != .portal {
            browser.setPortalStatus("Inactive in " + browser.backend.rawValue)
        }
        switch browser.backend {
        case .native:
            addSubview(left)
            left.addSubview(source)
        case .replica:
            configureReplica(wide: wide, eyeWidth: eyeWidth)
        case .portal:
            configurePortal(wide: wide)
        case .snapshot:
            configureSnapshot()
        }
        addSourceDots(wide: wide)
        if workspaceRendering {
            configureWorkspaceOverlays(wide: wide, eyeWidth: eyeWidth)
            return
        }
        configureBrowserChrome(wide: wide)
    }

    var usesWorkspace: Bool {
        workspaceRendering
    }
    func update(_ link: CADisplayLink, frame: RenderFrame) {
        if browser.phonePageActive && !usesWorkspace
            && (browser.backend != .replica || NativeInput.shared.phoneHosted)
        {
            showPhoneSignIn()
            return
        }
        if !usesWorkspace && lastRevision != browser.surfaceRevision {
            configure()
        }
        if configured != browser.backend || configuredPhoneHost != NativeInput.shared.phoneHosted
            || previousSize != bounds.size
        {
            configure()
        }
        let frame = browser.panelRelativeFrame(frame, now: CACurrentMediaTime())
        browser.updateWorkspacePointer(frame)
        if workspaceRendering {
            updateWorkspace(link, frame: frame)
            return
        }
        let wide = bounds.width / max(1, bounds.height) > 2.5
        let eyeWidth = wide ? bounds.width / 2 : bounds.width
        browser.frameStats.snapshotGPU =
            renderer.map { "submitted \($0.submittedFrames), skipped \($0.skippedFrames), error \($0.error ?? "none")" }
            ?? "Not active"
        let pixels = window?.windowScene?.screen.currentMode?.size
        if !browser.phonePageActive {
            var primaryFrame = frame
            primaryFrame.orientation = browser.offset.camera(frame.orientation)
            browser.tick(link, size: bounds.size, pixels: pixels, frame: primaryFrame)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<(wide ? 2 : 1) {
            updateEye(index, wide: wide, eyeWidth: eyeWidth, frame: frame)
        }
        browser.recordDriftFrame(
            frame, applied: nil, viewport: SIMD2(Float(eyeWidth), Float(bounds.height)),
            reportable: false, now: CACurrentMediaTime())
        CATransaction.commit()
        if browser.backend == .snapshot {
            renderer?.frame = frame
            metal?.draw()
        }
    }
    // Places the page, toolbar and cursor dot for one eye of the single-page view.
    private func updateEye(_ index: Int, wide: Bool, eyeWidth: CGFloat, frame: RenderFrame) {
        // The replicator copies one view to both eyes, so only other backends offset each eye.
        var offset: Float = 0
        if wide && browser.backend != .replica {
            let side: Float = index == 0 ? -0.5 : 0.5
            offset = side * frame.settings.eyeSeparationMillimeters / 1000
        }
        let camera = browser.offset.camera(frame.orientation)
        let transform = WebPanelMath.screenTransform(
            camera: camera, eyeOffset: offset,
            viewport: SIMD2(Float(eyeWidth), Float(bounds.height)), settings: frame.settings)
        if browser.backend != .snapshot {
            if index == 0 {
                source.layer.transform = caTransform(transform)
                source.isHidden = configured != .snapshot && !isInFront(transform)
            } else if browser.backend == .portal {
                portal?.isHidden = !isInFront(transform)
                portal?.layer.transform = caTransform(transform)
            }
        }
        if index < chrome.count {
            let controls = chrome[index]
            controls.refresh(with: browser)
            if index == 1 {
                controls.isHidden = browser.backend == .snapshot || !isInFront(transform)
                controls.layer.transform = caTransform(transform)
            }
        }
        updateCursorDot(index, transform: transform, eyeWidth: eyeWidth, frame: frame)
    }

    private func updateCursorDot(_ index: Int, transform: simd_float4x4, eyeWidth: CGFloat, frame: RenderFrame) {
        let dot = dots[index]
        let selected = browser.selectedSession
        let pointerPanel: BrowserScreen
        let cursorPoint: SIMD2<Float>?
        if browser.workspace.input != .trackpad, browser.visiblePanels.count > 1 {
            let hit = browser.workspace.pointerHit
            pointerPanel = browser.visiblePanels.first { $0.panelNumber == hit?.panel } ?? selected
            cursorPoint = hit?.point
        } else {
            pointerPanel = selected
            cursorPoint = selected.effectiveCursor
        }
        guard let cursor = cursorPoint, browser.signInSession == nil, selected.popup == nil else {
            dot.isHidden = true
            return
        }
        // The replicator uses the same center projection in both eyes.
        let cursorTransform: simd_float4x4
        if pointerPanel === browser {
            cursorTransform = transform
        } else {
            cursorTransform = WebPanelMath.screenTransform(
                camera: pointerPanel.offset.camera(frame.orientation), eyeOffset: 0,
                viewport: SIMD2(Float(eyeWidth), Float(bounds.height)), settings: frame.settings)
        }
        let point = cursorTransform * SIMD4(cursor.x, cursor.y, 0, 1)
        guard isInFront(cursorTransform), point.w > 0.03 else {
            dot.isHidden = true
            return
        }
        let x = point.x / point.w
        let y = point.y / point.w
        dot.isHidden = point.w <= 0 || x < 0 || x > Float(eyeWidth) || y < 0 || y > Float(bounds.height)
        dot.center = CGPoint(x: CGFloat(x) + CGFloat(index) * eyeWidth, y: CGFloat(y))
    }

    private func showPhoneSignIn() {
        if configured != nil || phoneSignInLabels.isEmpty || signInLayout != bounds.size {
            stop()
            signInLayout = bounds.size
            let eyes = bounds.width / max(1, bounds.height) > 2.5 ? 2 : 1
            let width = bounds.width / CGFloat(eyes)
            for eye in 0..<eyes {
                let label = UILabel(
                    frame: CGRect(x: CGFloat(eye) * width, y: 0, width: width, height: bounds.height))
                label.text = "Continue sign-in on iPhone"
                label.font = .systemFont(ofSize: 38, weight: .medium)
                label.textAlignment = .center
                label.textColor = .white
                addSubview(label)
                phoneSignInLabels.append(label)
            }
        }
    }

    func projectedPanelRect(_ transform: simd_float4x4) -> CGRect? {
        let corners: [SIMD4<Float>] = [
            SIMD4(0, -56, 0, 1), SIMD4(1000, -56, 0, 1), SIMD4(0, 625, 0, 1), SIMD4(1000, 625, 0, 1)
        ]
        let points = corners.map { transform * $0 }
        guard points.allSatisfy({ $0.w > 0.04 }) else {
            return nil
        }
        return points.reduce(CGRect.null) { rect, point in
            rect.union(CGRect(x: CGFloat(point.x / point.w), y: CGFloat(point.y / point.w), width: 0.01, height: 0.01))
        }
    }
    func isInFront(_ transform: simd_float4x4) -> Bool {
        let corners: [SIMD4<Float>] = [
            SIMD4(0, -56, 0, 1), SIMD4(1000, -56, 0, 1), SIMD4(0, 625, 0, 1), SIMD4(1000, 625, 0, 1)
        ]
        return corners.allSatisfy { (transform * $0).w > 0.04 }
    }

    func matrix(_ transform: CATransform3D) -> simd_float4x4 {
        simd_float4x4(
            columns: (
                SIMD4(Float(transform.m11), Float(transform.m12), Float(transform.m13), Float(transform.m14)),
                SIMD4(Float(transform.m21), Float(transform.m22), Float(transform.m23), Float(transform.m24)),
                SIMD4(Float(transform.m31), Float(transform.m32), Float(transform.m33), Float(transform.m34)),
                SIMD4(Float(transform.m41), Float(transform.m42), Float(transform.m43), Float(transform.m44))
            ))
    }
    func caTransform(_ transform: simd_float4x4) -> CATransform3D {
        CATransform3D(
            m11: CGFloat(transform[0][0]), m12: CGFloat(transform[0][1]),
            m13: CGFloat(transform[0][2]), m14: CGFloat(transform[0][3]),
            m21: CGFloat(transform[1][0]), m22: CGFloat(transform[1][1]),
            m23: CGFloat(transform[1][2]), m24: CGFloat(transform[1][3]),
            m31: CGFloat(transform[2][0]), m32: CGFloat(transform[2][1]),
            m33: CGFloat(transform[2][2]), m34: CGFloat(transform[2][3]),
            m41: CGFloat(transform[3][0]), m42: CGFloat(transform[3][1]),
            m43: CGFloat(transform[3][2]), m44: CGFloat(transform[3][3]))
    }
}
