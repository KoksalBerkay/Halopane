import Foundation
import CoreGraphics
import simd

/// Insets relative to one eye, independent of the current display mode.
public struct VisibleArea: Codable, Equatable {
    public var top: Double = 0.06
    public var bottom: Double = 0
    public var left: Double = 0
    public var right: Double = 0
    public init() {}

    public func rect(in size: CGSize) -> CGRect {
        func limit(_ value: Double) -> CGFloat {
            CGFloat(value.isFinite ? min(max(value, 0), 0.25) : 0)
        }
        let leftInset = limit(left)
        let rightInset = limit(right)
        let topInset = limit(top)
        let bottomInset = limit(bottom)
        return CGRect(
            x: leftInset * size.width, y: topInset * size.height,
            width: (1 - leftInset - rightInset) * size.width,
            height: (1 - topInset - bottomInset) * size.height)
    }
}

/// One reversible animation for entering and leaving. The caller supplies the
/// current world-relative camera on every frame, including on exit.
public struct PanelExpansion {
    private static let expansionSeconds: TimeInterval = 0.35
    private static let fadeSeconds: TimeInterval = 0.2

    private var started: TimeInterval = 0
    private var from: Float = 0
    private var fromOpacity: CGFloat = 1
    public private(set) var isExpanded = false

    public init() {}
    public func blend(at now: TimeInterval) -> Float {
        let t = min(1, max(0, Float((now - started) / Self.expansionSeconds)))
        let eased = t * t * (3 - 2 * t)
        return from + ((isExpanded ? 1 : 0) - from) * eased
    }
    public mutating func setExpanded(_ expanded: Bool, at now: TimeInterval) {
        guard expanded != isExpanded else {
            return
        }
        from = blend(at: now)
        fromOpacity = otherOpacity(at: now)
        started = now
        isExpanded = expanded
    }
    public func otherOpacity(at now: TimeInterval) -> CGFloat {
        let target: CGFloat = isExpanded ? 0 : 1
        let t = min(1, max(0, CGFloat((now - started) / Self.fadeSeconds)))
        return fromOpacity + (target - fromOpacity) * t
    }
}

/// Transforms a screen from its slot to filling the visible area.
public struct FullScreenGeometry {
    public let depth: Float
    public let offset: SIMD2<Float>
    public let visibleLocalY: ClosedRange<Float>

    public init(viewport: SIMD2<Float>, visible: CGRect, settings: SceneSettings, content: CGRect) {
        let focalLengthX = viewport.x / (2 * tan(min(max(settings.horizontalFOV, 10), 120) * .pi / 360))
        let focalLengthY = viewport.y / (2 * tan(min(max(settings.verticalFOV, 10), 100) * .pi / 360))
        let fittedDepth = max(
            focalLengthX * WebPanelMath.width * Float(content.width) / 1000 / max(1, Float(visible.width)),
            focalLengthY * WebPanelMath.height * Float(content.height) / 625 / max(1, Float(visible.height)))
        depth = max(0.08, fittedDepth)
        let projectedHeight = focalLengthY * WebPanelMath.height / depth
        // Cinema's crop is centered as well. Whole-page dimensions and pixel mapping remain unchanged.
        offset = SIMD2(Float(visible.midX) - viewport.x / 2, Float(visible.midY) - viewport.y / 2)
        let halfHeight = Float(visible.height) / max(1, projectedHeight) * 312.5
        visibleLocalY = (312.5 - halfHeight)...(312.5 + halfHeight)
    }

    public func transform(camera: simd_quatf, blend: Float, viewport: SIMD2<Float>, settings: SceneSettings)
        -> simd_float4x4
    {
        let t = min(1, max(0, blend))
        return WebPanelMath.screenTransform(
            camera: simd_slerp(camera, SceneMath.identity, t), eyeOffset: 0,
            viewport: viewport, settings: settings, depth: WebPanelMath.depth + (depth - WebPanelMath.depth) * t,
            screenOffset: offset * t)
    }
}
