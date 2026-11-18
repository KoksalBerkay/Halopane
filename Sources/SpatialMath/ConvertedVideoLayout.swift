import CoreGraphics
import Foundation

/// Where web video converted to 3D sits in the glasses. The video is fitted
/// inside the visible part of the left eye. A layer mesh draws it there and a
/// second time, one eye width to the right, for the right eye.
public struct ConvertedVideoLayout: Equatable {
    /// The video's place in the left eye, in surface points.
    public let fitted: CGRect
    /// Page points to surface points.
    public let scale: CGFloat
    /// Centre of the whole page in the fitted rectangle's own coordinates.
    public let pageCenter: CGPoint
    /// How far the right eye's copy sits from the left one, in fitted widths.
    public let rightEyeOffset: CGFloat

    /// `crop` is the video's rectangle on the page, in page points.
    public init?(
        crop: CGRect, eyeSize: CGSize, visible: CGRect, pageSize: CGSize = CGSize(width: 1000, height: 625)
    ) {
        let area = visible.intersection(CGRect(origin: .zero, size: eyeSize))
        guard
            [crop.minX, crop.minY, crop.width, crop.height, area.width, area.height].allSatisfy(\.isFinite),
            crop.width > 1, crop.height > 1, area.width > 1, area.height > 1, eyeSize.width > 1
        else {
            return nil
        }
        let aspect = crop.width / crop.height
        let width = min(area.width, area.height * aspect)
        let height = width / aspect
        fitted = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        scale = width / crop.width
        pageCenter = CGPoint(
            x: (pageSize.width / 2 - crop.minX) * scale, y: (pageSize.height / 2 - crop.minY) * scale)
        rightEyeOffset = eyeSize.width / width
    }
}

extension StereoDepthMesh {
    /// Points for a layer mesh that draws the picture once per eye, left eye
    /// first. Each point is (from x, from y, to x, to y) in the layer's unit
    /// square. The right eye's copy moves `rightEyeOffset` layer widths right.
    public func layerPoints(rightEyeOffset: Float) -> [SIMD4<Float>] {
        var points: [SIMD4<Float>] = []
        points.reserveCapacity(columns * rows * 2)
        for eye in 0..<2 {
            let offset = eye == 0 ? 0 : rightEyeOffset
            for row in 0..<rows {
                for column in 0..<columns {
                    let from = sourcePoint(column: column, row: row)
                    let to = eyePoint(column: column, row: row, eye: eye)
                    points.append(SIMD4(from.x, from.y, to.x + offset, to.y))
                }
            }
        }
        return points
    }

    /// Four point indices per cell, clockwise from the top left, for both copies.
    public func layerQuads() -> [UInt32] {
        var quads: [UInt32] = []
        quads.reserveCapacity((columns - 1) * (rows - 1) * 8)
        let perEye = columns * rows
        for eye in 0..<2 {
            for row in 0..<(rows - 1) {
                for column in 0..<(columns - 1) {
                    let topLeft = UInt32(eye * perEye + row * columns + column)
                    let bottomLeft = topLeft + UInt32(columns)
                    quads += [topLeft, topLeft + 1, bottomLeft + 1, bottomLeft]
                }
            }
        }
        return quads
    }
}
