import MetalKit
import QuartzCore
import SpatialMath
import UIKit
import simd

/// The pointer and laser beam drawn across screens.
final class WorkspacePointer: UIView {
    private let core = CALayer()
    private let halo = CAGradientLayer()
    private let beam = CAGradientLayer()
    private let beamMask = CAShapeLayer()
    private var lastLocal: SIMD2<Float>?
    private var lastPanel = 0
    private var lastMove: CFTimeInterval = 0
    private var hoverProbeAt: CFTimeInterval = 0
    private var hoverPanel = 0
    private var hoverResult = false
    private var hoverInFlight = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        beam.colors = [UIColor.clear.cgColor, UIColor(red: 0.8, green: 0.98, blue: 1, alpha: 0.56).cgColor]
        beam.mask = beamMask
        beamMask.fillColor = UIColor.white.cgColor
        layer.addSublayer(beam)
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.colors = [UIColor.white.withAlphaComponent(0.28).cgColor, UIColor.clear.cgColor]
        layer.addSublayer(halo)
        core.backgroundColor = UIColor.white.cgColor
        core.borderColor = UIColor(white: 0.16, alpha: 0.9).cgColor
        core.borderWidth = 1.5
        layer.addSublayer(core)
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    func hide() {
        core.isHidden = true
        halo.isHidden = true
        beam.isHidden = true
    }
    func hover(session: BrowserScreen, point: SIMD2<Float>, now: CFTimeInterval) -> Bool {
        if hoverPanel != session.panelNumber {
            hoverPanel = session.panelNumber
            hoverResult = false
        }
        guard point.y >= 0, !hoverInFlight, now - hoverProbeAt > 0.15 else {
            return hoverResult
        }
        hoverInFlight = true
        hoverProbeAt = now
        let id = session.panelNumber
        session.web.callAsyncJavaScript(
            """
            const node = document.elementFromPoint(x * innerWidth,y * innerHeight);
            return !!node?.closest('a[href],button,input,select,textarea,[role="button"]');
            """, arguments: ["x": point.x / 1000, "y": point.y / 625], in: nil, in: .defaultClient
        ) { [weak self] result in
            guard let self else {
                return
            }
            self.hoverInFlight = false
            if self.hoverPanel == id {
                self.hoverResult = (try? result.get()) as? Bool ?? false
            }
        }
        return hoverResult
    }
    func drawMiss(at point: CGPoint) {
        let size: CGFloat = 10
        core.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        core.cornerRadius = size / 2
        core.opacity = 0.25
        core.isHidden = false
        lastLocal = nil
    }
    func draw(
        at point: CGPoint, local: SIMD2<Float>, panel: Int, playing: Bool, tap: CFTimeInterval,
        now: CFTimeInterval, hand: CGPoint?, visible: CGRect, hover: Bool
    ) {
        if lastPanel != panel || lastLocal.map({ simd_distance($0, local) > 2 }) != false {
            lastPanel = panel
            lastLocal = local
            lastMove = now
        }
        let idle = now - max(lastMove, tap)
        let opacity = playing ? Float(1 - min(1, max(0, (idle - 3) / 0.18))) : 1
        guard opacity > 0 else {
            return
        }
        let pulse = CGFloat(max(0, 1 - (now - tap) / 0.12))
        let haloSize = 40 + 12 * pulse
        let size: CGFloat = hover ? 22 : 18
        halo.frame = CGRect(x: point.x - haloSize / 2, y: point.y - haloSize / 2, width: haloSize, height: haloSize)
        halo.opacity = opacity
        halo.isHidden = false
        core.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        core.cornerRadius = size / 2
        core.opacity = opacity
        core.isHidden = false
        if let hand {
            drawBeam(hand: hand, tip: point, visible: visible, opacity: opacity)
        }
    }

    private func drawBeam(hand: CGPoint, tip: CGPoint, visible: CGRect, opacity: Float) {
        let dx = tip.x - hand.x, dy = tip.y - hand.y
        let length = hypot(dx, dy)
        guard length > 6, bounds.width > 0, bounds.height > 0 else {
            return
        }
        var entry: CGFloat = 0
        if hand.x < visible.minX, dx > 0 {
            entry = max(entry, (visible.minX - hand.x) / dx)
        }
        if hand.x > visible.maxX, dx < 0 {
            entry = max(entry, (visible.maxX - hand.x) / dx)
        }
        if hand.y < visible.minY, dy > 0 {
            entry = max(entry, (visible.minY - hand.y) / dy)
        }
        if hand.y > visible.maxY, dy < 0 {
            entry = max(entry, (visible.maxY - hand.y) / dy)
        }
        guard entry < 0.99 else {
            return
        }
        let start = CGPoint(x: hand.x + entry * dx, y: hand.y + entry * dy)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: start.x + normal.x * 3, y: start.y + normal.y * 3))
        path.addLine(to: CGPoint(x: tip.x + normal.x, y: tip.y + normal.y))
        path.addLine(to: CGPoint(x: tip.x - normal.x, y: tip.y - normal.y))
        path.addLine(to: CGPoint(x: start.x - normal.x * 3, y: start.y - normal.y * 3))
        path.close()
        beam.frame = bounds
        beamMask.frame = bounds
        // The hand endpoint is clipped to the visible area; keep the gradient relative to the beam.
        beamMask.path = path.cgPath
        beamMask.shadowColor = UIColor.cyan.cgColor
        beamMask.shadowOpacity = 0.33
        beamMask.shadowRadius = 3
        beamMask.shadowOffset = .zero
        beam.startPoint = CGPoint(x: start.x / bounds.width, y: start.y / bounds.height)
        beam.endPoint = CGPoint(x: tip.x / bounds.width, y: tip.y / bounds.height)
        beam.opacity = opacity
        beam.isHidden = !visible.contains(tip)
    }
}
