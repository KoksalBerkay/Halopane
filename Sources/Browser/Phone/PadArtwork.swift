import AdapterTracking
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// Draws the trackpad surface and touch feedback.
final class PadArtwork: UIView {
    private static let accent = UIColor(red: 95 / 255, green: 208 / 255, blue: 228 / 255, alpha: 1)
    private static let amber = UIColor(red: 240 / 255, green: 183 / 255, blue: 101 / 255, alpha: 1)
    private static let edgeColor = UIColor(red: 29 / 255, green: 38 / 255, blue: 49 / 255, alpha: 1)
    private let base = CAGradientLayer()
    private let edge = UIView()
    private let grid = CAShapeLayer()
    private let gridMask = CAGradientLayer()
    private let feedback = UIView()
    private let flash = UILabel()
    private let holdLabel = UILabel()
    private let rail = UIView()
    private let thumb = UIView()
    private lazy var glows = (0..<2).map { _ -> UIView in
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        let glow = CAGradientLayer()
        glow.frame = view.bounds
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [Self.accent.withAlphaComponent(0.34).cgColor, Self.accent.withAlphaComponent(0).cgColor]
        view.layer.addSublayer(glow)
        view.alpha = 0
        feedback.addSubview(view)
        return view
    }
    private var fingerPoints: [CGPoint] = []
    private var panelID: Int?
    private var expanded = false
    private var scrollPosition: CGFloat = 0.5
    private var scrollFade: DispatchWorkItem?
    var motionReduced = false
    var playing = false {
        didSet {
            if oldValue != playing {
                feedback.alpha = playing ? 0.5 : 1
                if playing {
                    flash.layer.removeAllAnimations()
                    flash.alpha = 0
                }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 28
        base.type = .radial
        base.startPoint = CGPoint(x: 0.5, y: 0.38)
        base.endPoint = CGPoint(x: 1, y: 1)
        base.colors = [
            UIColor(red: 19 / 255, green: 26 / 255, blue: 34 / 255, alpha: 1).cgColor,
            UIColor(red: 14 / 255, green: 19 / 255, blue: 25 / 255, alpha: 1).cgColor
        ]
        layer.addSublayer(base)
        grid.fillColor = UIColor.white.withAlphaComponent(0.04).cgColor
        gridMask.type = .radial
        gridMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        gridMask.endPoint = CGPoint(x: 1, y: 1)
        gridMask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        gridMask.locations = [0.27, 0.92]
        grid.mask = gridMask
        layer.addSublayer(grid)
        addSubview(feedback)
        addSubview(edge)
        edge.layer.borderWidth = 1
        edge.layer.cornerRadius = 28
        edge.layer.borderColor = Self.edgeColor.cgColor
        flash.textAlignment = .center
        flash.font = .systemFont(ofSize: 140, weight: .semibold)
        flash.textColor = Self.accent
        flash.alpha = 0
        feedback.addSubview(flash)
        holdLabel.text = "Recenter"
        holdLabel.textAlignment = .center
        holdLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        holdLabel.textColor = Self.accent
        holdLabel.alpha = 0
        feedback.addSubview(holdLabel)
        rail.backgroundColor = Self.accent.withAlphaComponent(0.15)
        rail.layer.cornerRadius = 1.5
        thumb.backgroundColor = Self.accent.withAlphaComponent(0.6)
        thumb.layer.cornerRadius = 1.5
        rail.addSubview(thumb)
        rail.alpha = 0
        feedback.addSubview(rail)
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        grid.frame = bounds
        gridMask.frame = bounds
        let dots = CGMutablePath()
        for x in stride(from: bounds.midX.truncatingRemainder(dividingBy: 24), to: bounds.width, by: 24) {
            for y in stride(from: bounds.midY.truncatingRemainder(dividingBy: 24), to: bounds.height, by: 24) {
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
        }
        grid.path = dots
        CATransaction.commit()
        edge.frame = bounds
        feedback.frame = bounds
        flash.frame = bounds
        holdLabel.frame = bounds
        rail.frame = CGRect(x: bounds.width - 8, y: bounds.height * 0.28, width: 3, height: bounds.height * 0.44)
        layoutThumb()
    }

    func setFullScreen(_ on: Bool) {
        guard expanded != on else {
            return
        }
        expanded = on
        let tint = on ? Self.accent.cgColor : Self.edgeColor.cgColor
        if !motionReduced {
            let animation = CABasicAnimation(keyPath: "borderColor")
            animation.fromValue = edge.layer.presentation()?.borderColor ?? edge.layer.borderColor
            animation.toValue = tint
            animation.duration = 0.25
            edge.layer.add(animation, forKey: "edgeTint")
        }
        edge.layer.borderColor = tint
    }

    func showPanel(id: Int?, label: Int) {
        guard id != panelID else {
            return
        }
        let prior = panelID
        panelID = id
        guard prior != nil, id != nil, !playing else {
            return
        }
        flash.layer.removeAllAnimations()
        flash.text = String(label)
        flash.alpha = motionReduced ? 0.10 : 0.16
        UIView.animate(
            withDuration: motionReduced ? 0 : 0.6, delay: motionReduced ? 0.4 : 0,
            options: .beginFromCurrentState
        ) {
            self.flash.alpha = 0
        }
    }

    func showFingers(_ points: [CGPoint]) {
        fingerPoints = points
        holdLabel.alpha = 0
        for (index, view) in glows.enumerated() {
            if index < points.count {
                view.center = points[index]
                if view.alpha != 1 {
                    UIView.animate(withDuration: 0.08, delay: 0, options: .beginFromCurrentState) {
                        view.alpha = 1
                    }
                }
            } else if view.alpha > 0 {
                UIView.animate(withDuration: 0.22, delay: 0, options: .beginFromCurrentState) {
                    view.alpha = 0
                }
            }
        }
    }

    func prepareRecenter() {
        guard fingerPoints.count == 2 else {
            return
        }
        if motionReduced {
            holdLabel.alpha = 0.6
            return
        }
        let point = CGPoint(
            x: (fingerPoints[0].x + fingerPoints[1].x) / 2, y: (fingerPoints[0].y + fingerPoints[1].y) / 2)
        UIView.animate(withDuration: 0.22, delay: 0, options: .beginFromCurrentState) {
            self.glows.forEach {
                $0.center = point
            }
        }
    }

    func pulse(at point: CGPoint, secondary: Bool = false) {
        guard !isHidden else {
            return
        }
        let tint = secondary ? Self.amber : Self.accent
        let shape = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        shape.center = point
        shape.layer.cornerRadius = 18
        shape.layer.borderWidth = motionReduced ? 0 : 1.5
        shape.layer.borderColor = tint.cgColor
        if motionReduced {
            shape.backgroundColor = tint.withAlphaComponent(0.6)
        }
        shape.alpha = motionReduced ? 1 : 0.6
        feedback.addSubview(shape)
        let reduced = motionReduced
        UIView.animate(withDuration: reduced ? 0.1 : 0.18, delay: 0, options: .curveEaseOut) {
            if !reduced {
                let scale: CGFloat = secondary ? 90 / 36 : 110 / 36
                shape.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
            shape.alpha = 0
        } completion: { _ in
            shape.removeFromSuperview()
        }
    }

    func noteScroll(_ dy: CGFloat) {
        guard !isHidden else {
            return
        }
        if motionReduced {
            scrollPosition = 0.5
        } else {
            scrollPosition = min(max(scrollPosition - dy / 180, 0), 1)
        }
        layoutThumb()
        rail.layer.removeAllAnimations()
        rail.alpha = 1
        scrollFade?.cancel()
        let fade = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.13) {
                self?.rail.alpha = 0
            }
        }
        scrollFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: fade)
    }

    private func layoutThumb() {
        let height = min(22, rail.bounds.height)
        thumb.frame = CGRect(x: 0, y: (rail.bounds.height - height) * scrollPosition, width: 3, height: height)
    }
}
