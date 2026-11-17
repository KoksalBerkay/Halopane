import CoreGraphics

/// Maps a video on the page to the full visible area, and pointer positions back.
public struct CinemaMapping: Equatable {
    public let crop: CGRect
    public let destination: CGRect
    public init?(crop: CGRect, panelSize: CGSize = CGSize(width: 1000, height: 625)) {
        guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
            crop.width > 1, crop.height > 1,
            CGRect(origin: .zero, size: panelSize).contains(crop)
        else {
            return nil
        }
        self.crop = crop
        let scale = min(panelSize.width / crop.width, panelSize.height / crop.height)
        let size = CGSize(width: crop.width * scale, height: crop.height * scale)
        destination = CGRect(
            x: (panelSize.width - size.width) / 2, y: (panelSize.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    public var scale: CGFloat { destination.width / crop.width }

    public func sourcePoint(at point: CGPoint) -> CGPoint? {
        guard destination.contains(point) else {
            return nil
        }
        return CGPoint(
            x: crop.minX + (point.x - destination.minX) / scale,
            y: crop.minY + (point.y - destination.minY) / scale)
    }
}

/// How a 3D video stores its two eyes in one frame.
public enum StereoPacking: String, CaseIterable, Identifiable {
    case sideBySide = "Side by side"
    case halfSideBySide = "Half side by side"

    public var id: Self { self }
}

/// Maps a single packed video across two physical eyes. The split is fixed at
/// the display seam; the calibrated visible area clips both eyes equally.
public struct StereoCinemaLayout: Equatable {
    public let packedFrame: CGRect
    public let eyeClip: CGRect
    public let instanceOffset: CGFloat
    public let scaleX: CGFloat
    public let scaleY: CGFloat

    public init?(crop: CGRect, eyeSize: CGSize, visible: CGRect, packing: StereoPacking, swapped: Bool = false) {
        let eye = CGRect(origin: .zero, size: eyeSize)
        let clip = visible.intersection(eye)
        guard
            [crop.minX, crop.minY, crop.width, crop.height, eye.width, eye.height, clip.width, clip.height].allSatisfy(
                \.isFinite),
            crop.width > 1, crop.height > 1, eye.width > 1, eye.height > 1, clip.width > 1, clip.height > 1
        else {
            return nil
        }
        scaleX = 2 * eye.width / crop.width
        scaleY = scaleX / (packing == .halfSideBySide ? 2 : 1)
        let height = crop.height * scaleY
        guard height.isFinite else {
            return nil
        }
        packedFrame = CGRect(
            x: swapped ? -eye.width : 0, y: clip.midY - height / 2, width: 2 * eye.width, height: height)
        eyeClip = clip
        // Swap by displaying the right half of the first draw and the left
        // half of a second draw. The other halves are outside the display.
        instanceOffset = swapped ? 2 * eye.width : 0
    }
}
