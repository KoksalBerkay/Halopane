import AdapterTracking
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// The phone trackpad: move, click, right-click, scroll, pinch and recenter.
struct WebTouchpad: UIViewRepresentable {
    var swipeToScroll: Bool
    var move: (CGPoint) -> Void
    var click: () -> Void
    var scroll: (Float) -> Void
    var beginScroll: () -> Void
    var stopScroll: () -> Void
    var endScroll: (CGFloat) -> Void = { _ in }
    var recenter: (() -> Void)? = nil
    var dark = false
    var fullScreen = false
    var playing = false
    var reduceMotion = false
    var selectedPanel: Int? = nil
    var panelLabel = 1
    var secondaryClick: (() -> Void)? = nil
    var photoPinch: ((CGFloat) -> Void)? = nil
    func makeUIView(context: Context) -> Pad {
        let pad = Pad()
        updateUIView(pad, context: context)
        return pad
    }
    func updateUIView(_ view: Pad, context: Context) {
        view.swipeToScroll = swipeToScroll
        view.move = move
        view.click = click
        view.scroll = scroll
        view.beginScroll = beginScroll
        view.stopScroll = stopScroll
        view.endScroll = endScroll
        view.recenter = recenter
        view.secondaryClick = secondaryClick
        view.photoPinch = photoPinch
        view.configure(
            dark: dark, fullScreen: fullScreen, playing: playing, reduceMotion: reduceMotion,
            selectedPanel: selectedPanel, panelLabel: panelLabel)
    }

    /// The UIKit view behind WebTouchpad, with its gesture recognizers.
    final class Pad: UIView, UIGestureRecognizerDelegate {
        var move: (CGPoint) -> Void = { _ in }, click: () -> Void = {}, scroll: (Float) -> Void = { _ in }
        var beginScroll: () -> Void = {}, stopScroll: () -> Void = {}
        var endScroll: (CGFloat) -> Void = { _ in }
        private weak var twoFingerPan: UIPanGestureRecognizer?
        var photoPinch: ((CGFloat) -> Void)? {
            didSet {
                let enabled = photoPinch != nil
                if pinchGesture.isEnabled != enabled {
                    pinchGesture.isEnabled = enabled
                }
                if twoFingerPan?.isEnabled == enabled {
                    twoFingerPan?.isEnabled = !enabled
                }
            }
        }
        private lazy var pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        private var scrollRecognizer: UIGestureRecognizer?
        private let artwork = PadArtwork()
        private lazy var fingers = PadFingers(target: nil, action: nil)
        private var holdCue: DispatchWorkItem?
        private var cursorCarry = CGPoint.zero
        var secondaryClick: (() -> Void)? {
            didSet {
                let enabled = secondaryClick != nil
                if rightTap.isEnabled != enabled {
                    rightTap.isEnabled = enabled
                }
            }
        }
        private lazy var rightTap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
            tap.numberOfTouchesRequired = 2
            return tap
        }()
        var recenter: (() -> Void)? {
            didSet {
                centerGesture.isEnabled = recenter != nil
            }
        }
        private lazy var centerGesture: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            gesture.numberOfTouchesRequired = 2
            gesture.minimumPressDuration = 0.55
            gesture.allowableMovement = 12
            return gesture
        }()
        var swipeToScroll = false {
            didSet {
                label.text = swipeToScroll ? "Tap to select • Swipe to scroll" : Self.defaultLabel
            }
        }
        private static let defaultLabel = "One finger: move cursor\nTwo fingers: scroll\nTap: click"
        private let label = UILabel()
        private var previous = CGPoint.zero
        private var previousTwo = CGPoint.zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .secondarySystemBackground
            layer.cornerRadius = 20
            layer.borderWidth = 2
            layer.borderColor = UIColor.systemCyan.cgColor
            label.text = Self.defaultLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            let one = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            one.maximumNumberOfTouches = 1
            let two = UIPanGestureRecognizer(target: self, action: #selector(two(_:)))
            two.minimumNumberOfTouches = 2
            two.maximumNumberOfTouches = 2
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            tap.require(toFail: one)
            tap.require(toFail: two)
            one.delegate = self
            two.delegate = self
            addGestureRecognizer(one)
            addGestureRecognizer(two)
            addGestureRecognizer(tap)
            twoFingerPan = two
            addGestureRecognizer(pinchGesture)
            pinchGesture.isEnabled = false
            tap.require(toFail: pinchGesture)
            addGestureRecognizer(centerGesture)
            centerGesture.isEnabled = false
            tap.require(toFail: centerGesture)
            rightTap.require(toFail: two)
            rightTap.require(toFail: centerGesture)
            tap.require(toFail: rightTap)
            addGestureRecognizer(rightTap)
            rightTap.isEnabled = false
            artwork.isUserInteractionEnabled = false
            artwork.isAccessibilityElement = false
            artwork.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            artwork.frame = bounds
            artwork.isHidden = true
            addSubview(artwork)
            fingers.cancelsTouchesInView = false
            fingers.delaysTouchesBegan = false
            fingers.delaysTouchesEnded = false
            fingers.delegate = self
            fingers.changed = { [weak self] points in
                self?.showFingers(points)
            }
            addGestureRecognizer(fingers)
        }
        required init?(coder: NSCoder) {
            fatalError("Programmatic view")
        }
        func configure(
            dark: Bool, fullScreen: Bool, playing: Bool, reduceMotion: Bool,
            selectedPanel: Int?, panelLabel: Int
        ) {
            backgroundColor = dark ? .clear : .secondarySystemBackground
            label.isHidden = dark
            artwork.isHidden = !dark
            layer.borderWidth = dark ? 0 : 2
            artwork.motionReduced = reduceMotion
            artwork.playing = playing
            artwork.setFullScreen(fullScreen)
            if dark {
                artwork.showPanel(id: selectedPanel, label: panelLabel)
            }
        }
        private func showFingers(_ points: [CGPoint]) {
            holdCue?.cancel()
            guard !artwork.isHidden else {
                return
            }
            artwork.showFingers(points)
            guard points.count == 2, recenter != nil, scrollRecognizer == nil else {
                return
            }
            let cue = DispatchWorkItem { [weak self] in
                self?.artwork.prepareRecenter()
            }
            holdCue = cue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.33, execute: cue)
        }
        @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began, let recenter {
                holdCue?.cancel()
                artwork.pulse(at: gesture.location(in: self))
                recenter()
            }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if scrollRecognizer == nil {
                stopScroll()
            }
            super.touchesBegan(touches, with: event)
        }
        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended {
                artwork.pulse(at: gesture.location(in: self))
                click()
            }
        }
        @objc private func rightClick(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let secondaryClick else {
                return
            }
            cursorCarry = .zero
            holdCue?.cancel()
            artwork.pulse(at: gesture.location(in: self), secondary: true)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            secondaryClick()
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === fingers || otherGestureRecognizer === fingers
                || (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
        }
        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                holdCue?.cancel()
            }
            guard [.changed, .ended].contains(gesture.state) else {
                return
            }
            photoPinch?(gesture.scale)
            gesture.scale = 1
        }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            process(gesture, isScroll: swipeToScroll)
        }
        @objc private func two(_ gesture: UIPanGestureRecognizer) {
            process(gesture, isScroll: true)
        }
        private func process(_ gesture: UIPanGestureRecognizer, isScroll: Bool) {
            let point = gesture.translation(in: self)
            if gesture.state == .began {
                if isScroll {
                    holdCue?.cancel()
                    previousTwo = point
                    scrollRecognizer = gesture
                    beginScroll()
                } else {
                    previous = point
                    cursorCarry = .zero
                }
            }
            guard !isScroll || scrollRecognizer === gesture else {
                return
            }
            if gesture.state == .changed || gesture.state == .ended {
                let last = isScroll ? previousTwo : previous
                let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
                if isScroll {
                    scroll(Float(delta.y))
                    if delta.y != 0 {
                        artwork.noteScroll(delta.y)
                    }
                } else if secondaryClick == nil {
                    move(delta)
                } else if fingers.sawMultiple {
                    cursorCarry = .zero
                } else {
                    cursorCarry.x += delta.x
                    cursorCarry.y += delta.y
                    // Give a second finger time to land before moving the cursor.
                    if CACurrentMediaTime() - fingers.firstArrival >= 0.06 || gesture.state == .ended {
                        move(cursorCarry)
                        cursorCarry = .zero
                    }
                }
                if isScroll {
                    previousTwo = point
                } else {
                    previous = point
                }
            }
            if isScroll && [.ended, .cancelled, .failed].contains(gesture.state) {
                scrollRecognizer = nil
                if gesture.state == .ended {
                    endScroll(gesture.velocity(in: self).y)
                } else {
                    stopScroll()
                }
            }
        }
    }
}

// Observes the actual finger positions without delaying or claiming the pad gestures.
private final class PadFingers: UIGestureRecognizer {
    var changed: (([CGPoint]) -> Void)?
    private var touches: [UITouch] = []
    private(set) var firstArrival: CFTimeInterval = 0
    private(set) var sawMultiple = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if self.touches.isEmpty {
            firstArrival = CACurrentMediaTime()
            sawMultiple = false
        }
        self.touches.append(contentsOf: touches)
        if self.touches.count > 1 {
            sawMultiple = true
        }
        state = state == .possible ? .began : .changed
        report()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .changed
        report()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        remove(touches)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        remove(touches)
    }
    override func reset() {
        touches.removeAll()
        report()
        super.reset()
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
    private func remove(_ ended: Set<UITouch>) {
        touches.removeAll { ended.contains($0) }
        state = touches.isEmpty ? .ended : .changed
        report()
    }
    private func report() {
        changed?(touches.map { $0.location(in: view) })
    }
}
