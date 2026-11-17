import AdapterTracking
import Combine
import SwiftUI
import MetalKit
import SpatialMath
import simd
import UIKit

/// Identical labels in each eye, independent of the video surface.
final class ExternalMediaHUD: UIView {
    private let captions = (0..<2).map { _ -> UILabel in
        let label = UILabel()
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        label.font = .systemFont(ofSize: 27, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.10, alpha: 0.92)
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        return label
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        captions.forEach(addSubview)
    }
    required init?(coder: NSCoder) {
        fatalError("Programmatic view")
    }

    func show(_ message: String?, stereo: Bool, visibleArea: VisibleArea) {
        guard let message else {
            isHidden = true
            return
        }
        isHidden = false
        let eye = CGSize(width: bounds.width / (stereo ? 2 : 1), height: bounds.height)
        let visible = visibleArea.rect(in: eye)
        let width = max(1, min(880, visible.width - 24))
        let height = max(1, min(60, visible.height - 24))
        for (index, label) in captions.enumerated() {
            label.isHidden = index == 1 && !stereo
            if label.text != message {
                label.text = message
            }
            label.frame = CGRect(
                x: CGFloat(index) * eye.width + visible.midX - width / 2,
                y: visible.maxY - height - 16, width: width, height: height)
        }
    }
}

extension PausedMediaComparison {
    func uiImage(right wantsRight: Bool) -> UIImage? {
        guard let pixels = wantsRight ? right : left else {
            return nil
        }
        let orientations: [UIImage.Orientation] = [.up, .right, .down, .left]
        return UIImage(cgImage: pixels, scale: 1, orientation: orientations[Int(turns % 4)])
    }
}

/// Presents still or live image pairs directly on the external display.
/// It never reads from AVFoundation or uses a Metal drawable.
final class MediaComparisonImageSurface: UIView {
    private let first = UIImageView()
    private let second = UIImageView()
    private var frameID: UUID?
    private var currentEye: StereoEyePreview?
    private var wide = false

    init() {
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .black
        isHidden = true
        for view in [first, second] {
            view.contentMode = .scaleAspectFit
            view.backgroundColor = .black
            addSubview(view)
        }
    }
    required init?(coder: NSCoder) {
        nil
    }

    func show(_ comparison: PausedMediaComparison, eye: StereoEyePreview, stereo: Bool, visible: VisibleArea) {
        apply(
            id: comparison.id, eye: eye, swapped: false, stereo: stereo, visible: visible, image: comparison.uiImage
        )
    }

    func show(
        _ frame: LiveStereoImageFrame, eye: StereoEyePreview, swapped: Bool, stereo: Bool, visible: VisibleArea
    ) {
        apply(id: frame.id, eye: eye, swapped: swapped, stereo: stereo, visible: visible) { right in
            let rotation: [UIImage.Orientation] = [.up, .right, .down, .left]
            return UIImage(
                cgImage: right ? frame.right : frame.left, scale: 1, orientation: rotation[Int(frame.turns % 4)])
        }
    }

    func showPhoto(
        left: CGImage, right: CGImage?, id: UUID, eye: StereoEyePreview,
        swapped: Bool, stereo: Bool, visible: VisibleArea
    ) {
        apply(id: id, eye: eye, swapped: swapped && right != nil, stereo: stereo, visible: visible) { wantsRight in
            if wantsRight {
                return right.map { UIImage(cgImage: $0) }
            }
            return UIImage(cgImage: left)
        }
    }

    private var flipped = false
    private func apply(
        id: UUID, eye: StereoEyePreview, swapped: Bool, stereo: Bool, visible: VisibleArea,
        image: (Bool) -> UIImage?
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
        }
        if frameID != id || currentEye != eye || wide != stereo || flipped != swapped {
            frameID = id
            currentEye = eye
            wide = stereo
            flipped = swapped
            let firstRight = eye == .rightOnly || (eye == .stereo && stereo && swapped)
            let secondRight = eye == .rightOnly || (eye == .stereo && !swapped)
            first.image = image(firstRight)
            second.image = stereo ? image(secondRight) ?? first.image : nil
            second.isHidden = !stereo
        }
        let width = bounds.width / (stereo ? 2 : 1)
        let fit = visible.rect(in: CGSize(width: width, height: bounds.height))
        if first.frame != fit {
            first.frame = fit
        }
        if stereo {
            let rightFit = fit.offsetBy(dx: width, dy: 0)
            if second.frame != rightFit {
                second.frame = rightFit
            }
        }
        isHidden = false
    }

    func hideImages() {
        guard !isHidden else {
            return
        }
        isHidden = true
        first.image = nil
        second.image = nil
        frameID = nil
    }
}
