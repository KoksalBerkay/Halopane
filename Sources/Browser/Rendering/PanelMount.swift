import MetalKit
import QuartzCore
import SpatialMath
import UIKit
import simd

/// The packed video bypasses the workspace Replicator's per-eye clip. The
/// source is still the original web view; no video pixels are copied.
final class StereoVideoMount: UIView {
    private let instances = ReplicatorHost()
    private let packedClip = UIView()
    private let eyeMask = CAShapeLayer()
    private weak var session: BrowserScreen?
    private var lastLayout: StereoCinemaLayout?
    private var lastCrop: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        instances.clipsToBounds = false
        addSubview(instances)
        packedClip.clipsToBounds = true
        instances.addSubview(packedClip)
        layer.mask = eyeMask
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    func display(_ panel: BrowserScreen, crop: CGRect, layout: StereoCinemaLayout, eyeWidth: CGFloat) {
        let needsMount = session !== panel || panel.web.superview !== packedClip
        if needsMount {
            releaseVideo()
            session = panel
            packedClip.addSubview(panel.web)
        }
        isHidden = false
        guard needsMount || lastLayout != layout || lastCrop != crop else {
            return
        }
        lastLayout = layout
        lastCrop = crop
        instances.frame = bounds
        let replicator = instances.layer as! CAReplicatorLayer
        replicator.instanceCount = layout.instanceOffset == 0 ? 1 : 2
        replicator.instanceTransform = CATransform3DMakeTranslation(layout.instanceOffset, 0, 0)
        let path = CGMutablePath()
        path.addRect(layout.eyeClip)
        path.addRect(layout.eyeClip.offsetBy(dx: eyeWidth, dy: 0))
        eyeMask.frame = bounds
        eyeMask.path = path
        packedClip.frame = layout.packedFrame

        let web = panel.web
        web.transform = .identity
        web.bounds = CGRect(x: 0, y: 0, width: 1000, height: 625)
        web.transform = CGAffineTransform(scaleX: layout.scaleX, y: layout.scaleY)
        web.center = CGPoint(
            x: (web.bounds.midX - crop.minX) * layout.scaleX,
            y: (web.bounds.midY - crop.minY) * layout.scaleY)
    }

    func releaseVideo() {
        if let session {
            if session.web.superview === packedClip {
                session.web.removeFromSuperview()
                session.web.transform = .identity
            }
            session.setDrawingStereoVideo(false)
        }
        session = nil
        isHidden = true
        lastLayout = nil
        lastCrop = nil
    }
}

/// Holds one screen's web view in the glasses, including its first-paint warmup.
final class PanelMount: UIView {
    let session: BrowserScreen
    let chrome = BrowserChromeView()
    private let clipHost = UIView()
    private let border = UIView()
    private let signIn = UILabel()
    private var applied: CinemaMapping?
    private var revision = -1

    init(session: BrowserScreen) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 625))
        layer.anchorPoint = .zero
        layer.position = .zero
        clipHost.frame = bounds
        clipHost.clipsToBounds = true
        clipHost.isHidden = true
        addSubview(clipHost)
        addSubview(chrome)
        border.frame = bounds
        border.layer.borderWidth = 3
        border.layer.borderColor = UIColor.systemCyan.cgColor
        border.isUserInteractionEnabled = false
        addSubview(border)
        signIn.frame = bounds
        signIn.text = "Continue sign-in on iPhone"
        signIn.font = .systemFont(ofSize: 30, weight: .medium)
        signIn.textAlignment = .center
        signIn.textColor = .white
        signIn.backgroundColor = UIColor(white: 0.08, alpha: 1)
        addSubview(signIn)
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    private var warmSince: CFTimeInterval?
    private var committedFrames = 0
    var needsAttach: Bool { revision != session.surfaceRevision || !session.web.isDescendant(of: self) }
    var isWarming: Bool { warmSince != nil }

    func beginWarmup(at now: CFTimeInterval) {
        warmSince = now
        committedFrames = 0
        session.panelWarming = true
    }

    func advanceWarmup(now: CFTimeInterval, finished: Bool) -> Bool {
        guard let since = warmSince else {
            return false
        }
        if finished && !needsAttach {
            committedFrames += 1
        }
        guard (now - since >= 0.12 && committedFrames >= 3) || now - since >= 2.5 else {
            return false
        }
        warmSince = nil
        session.panelWarming = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        layer.add(fade, forKey: "panel reveal")
        return true
    }

    func detach() {
        session.panelWarming = false
        if session.web.isDescendant(of: self) {
            session.web.removeFromSuperview()
            session.web.transform = .identity
        }
        removeFromSuperview()
    }

    func refresh(focused: Bool, showBorder: Bool, showToolbar: Bool, toolbarTop: Float?) {
        border.isHidden = !focused || !showBorder
        signIn.isHidden = !session.phonePageActive
        chrome.refresh(
            with: session, focused: focused, showToolbar: showToolbar, toolbarTop: toolbarTop, inlineNotice: false)
        guard !session.phonePageActive else {
            return
        }
        let web = session.web
        let mapping = session.media.mapping
        guard !web.isDescendant(of: self) || mapping != applied || revision != session.surfaceRevision else {
            return
        }
        if revision != session.surfaceRevision, web.isDescendant(of: self) {
            web.removeFromSuperview()
        }
        revision = session.surfaceRevision
        session.media.trace("page attached")
        applied = mapping
        if let mapping {
            clipHost.isHidden = false
            let clip = CAShapeLayer()
            clip.frame = clipHost.bounds
            clip.path = CGPath(rect: mapping.destination, transform: nil)
            clipHost.layer.mask = clip
            if web.superview !== clipHost {
                clipHost.addSubview(web)
            }
            web.transform = .identity
            web.frame = bounds
            let scale = mapping.scale
            web.transform = CGAffineTransform(scaleX: scale, y: scale)
            web.center = CGPoint(
                x: mapping.destination.minX + (bounds.midX - mapping.crop.minX) * scale,
                y: mapping.destination.minY + (bounds.midY - mapping.crop.minY) * scale)
            backgroundColor = .black
        } else {
            if web.superview !== self {
                insertSubview(web, aboveSubview: clipHost)
            }
            web.transform = .identity
            web.frame = bounds
            clipHost.layer.mask = nil
            clipHost.isHidden = true
            backgroundColor = .clear
        }
        web.contentScaleFactor = 1
    }
}
