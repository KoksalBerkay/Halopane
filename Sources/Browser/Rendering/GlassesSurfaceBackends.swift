import MetalKit
import QuartzCore
import SpatialMath
import UIKit
import simd

// View setup for each rendering backend, called from configure().
extension GlassesSurface {
    // A replicator layer draws the left view a second time for the right eye.
    func configureReplica(wide: Bool, eyeWidth: CGFloat) {
        let host = ReplicatorHost(frame: bounds)
        let layer = host.layer as! CAReplicatorLayer
        layer.instanceCount = wide ? 2 : 1
        layer.instanceTransform = CATransform3DMakeTranslation(eyeWidth, 0, 0)
        host.addSubview(left)
        if !usesWorkspace {
            left.addSubview(source)
        }
        addSubview(host)
        replica = host
    }

    // Experimental: private portal views mirror the live web view into each eye.
    func configurePortal(wide: Bool) {
        addSubview(left)
        addSubview(right)
        left.addSubview(source)
        var detail: NSString?
        let sourceWidth = browser.web.bounds.width
        let normalizeScale = 1000 / max(sourceWidth, 1)
        func mount(_ mirror: UIView, in host: UIView) {
            mirror.bounds = browser.web.bounds
            mirror.layer.anchorPoint = .zero
            mirror.layer.position = .zero
            mirror.transform = CGAffineTransform(scaleX: normalizeScale, y: normalizeScale)
            host.addSubview(mirror)
        }
        var leftDetail: NSString?
        var leftCreated = !configuredPhoneHost
        if configuredPhoneHost {
            if let leftMirror = VXRCreateWebPortal(browser.web, &leftDetail) {
                mount(leftMirror, in: source)
                leftCreated = true
            }
        }
        var rightCreated = !wide
        if wide, let mirror = VXRCreateWebPortal(browser.web, &detail) {
            if configuredPhoneHost {
                let host = UIView(frame: source.bounds)
                host.layer.anchorPoint = .zero
                host.layer.position = .zero
                mount(mirror, in: host)
                right.addSubview(host)
                portal = host
            } else {
                mirror.frame = source.bounds
                mirror.layer.anchorPoint = .zero
                mirror.layer.position = .zero
                right.addSubview(mirror)
                portal = mirror
            }
            rightCreated = true
        }
        let result: String
        if leftCreated && rightCreated {
            result = "Portal views created; visual delivery unverified"
        } else {
            result = "Portal creation failed"
        }
        let leftStatus = (leftDetail as String?) ?? (configuredPhoneHost ? "unavailable" : "live source")
        let rightStatus = (detail as String?) ?? (wide ? "unavailable" : "mono")
        browser.setPortalStatus(result + " | left: " + leftStatus + " | right: " + rightStatus)
    }

    // Experimental: copies page snapshots into a Metal view.
    func configureSnapshot() {
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                let renderer = try WebSnapshotRenderer(device: device)
                let view = MTKView(frame: bounds, device: device)
                view.colorPixelFormat = .bgra8Unorm
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                view.isPaused = true
                view.enableSetNeedsDisplay = false
                view.delegate = renderer
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(view)
                self.renderer = renderer
                metal = view
                browser.uploadSnapshot = { [weak renderer] cg in
                    guard let renderer else {
                        throw WebSnapshotRenderer.Failure.noDevice
                    }
                    return try renderer.upload(cg)
                }
            } catch {
                browser.setPortalStatus("Snapshot Metal initialization: " + error.localizedDescription)
            }
        }
        // The visible source avoids silently substituting an occluded/offscreen WKWebView test.
        source.layer.transform = CATransform3DMakeScale(0.18, 0.18, 1)
        source.layer.position = CGPoint(x: 12, y: bounds.height - 125)
        addSubview(source)
    }

    // Cursor dots for the single-page view, one per eye. The workspace draws its own pointer.
    func addSourceDots(wide: Bool) {
        var count = 0
        if !usesWorkspace {
            count = wide ? 2 : 1
        }
        for _ in 0..<count {
            let dot = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
            dot.layer.cornerRadius = 8
            dot.layer.borderWidth = 2
            dot.layer.borderColor = UIColor.white.cgColor
            dot.layer.shadowColor = UIColor.black.cgColor
            dot.layer.shadowOpacity = 1
            dot.layer.shadowRadius = 1
            dot.layer.shadowOffset = .zero
            dot.isUserInteractionEnabled = false
            addSubview(dot)
            dots.append(dot)
        }
    }

    // 3D video layer, edge hint, notice, calibration frame and pointers for the workspace.
    func configureWorkspaceOverlays(wide: Bool, eyeWidth: CGFloat) {
        stereoVideo.frame = bounds
        stereoVideo.isHidden = true
        if let replica {
            insertSubview(stereoVideo, belowSubview: replica)
        }
        edgeHint.font = .systemFont(ofSize: 28, weight: .semibold)
        edgeHint.textAlignment = .center
        edgeHint.textColor = .white
        edgeHint.backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        edgeHint.layer.cornerRadius = 12
        edgeHint.clipsToBounds = true
        edgeHint.isUserInteractionEnabled = false
        left.addSubview(edgeHint)
        workspaceNotice.font = .systemFont(ofSize: 28, weight: .medium)
        workspaceNotice.textColor = .white
        workspaceNotice.textAlignment = .center
        workspaceNotice.backgroundColor = UIColor(white: 0.12, alpha: 0.94)
        workspaceNotice.layer.cornerRadius = 10
        workspaceNotice.clipsToBounds = true
        workspaceNotice.isUserInteractionEnabled = false
        left.addSubview(workspaceNotice)
        calibration.fillColor = UIColor.clear.cgColor
        calibration.strokeColor = UIColor.systemCyan.cgColor
        calibration.lineWidth = 3
        left.layer.addSublayer(calibration)
        // Match the diagnostic pointer's frontmost compositing path. The
        // layer tree under the replicator contains perspective web panels.
        for eye in 0..<(wide ? 2 : 1) {
            let pointer = WorkspacePointer()
            pointer.frame = left.bounds.offsetBy(dx: CGFloat(eye) * eyeWidth, dy: 0)
            pointer.clipsToBounds = true
            pointer.layer.zPosition = 20
            addSubview(pointer)
            workspacePointers.append(pointer)
        }
    }

    // Browser toolbar drawn into the source page, once per eye where needed.
    func configureBrowserChrome(wide: Bool) {
        for host in (wide ? [source, right] : [source]) {
            let controls = BrowserChromeView()
            host.addSubview(controls)
            chrome.append(controls)
        }
        // The Replicator copies the entire left source, including its controls.
        if browser.backend == .replica, chrome.count == 2 {
            chrome.removeLast().removeFromSuperview()
        }
        if browser.backend == .snapshot {
            chrome.forEach {
                $0.isHidden = true
            }
        }
        lastRevision = browser.surfaceRevision
    }
}
