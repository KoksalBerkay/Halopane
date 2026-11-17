import Foundation
import simd

/// A direction from the head, used to find what the pointer is aimed at.
public struct PointerRay {
    public let direction: SIMD3<Float>
    public init?(direction: SIMD3<Float>) {
        let length = simd_length(direction)
        guard length.isFinite, length > 0.0001 else {
            return nil
        }
        self.direction = direction / length
    }
}

/// Turns the phone's orientation into a pointer ray.
public struct PhoneAim {
    private let alignment: simd_quatf
    // Comfortable neutral pose: screen up, top edge forward.
    // Device +X -> head +X; device +Y -> head -Z; device +Z -> head +Y.
    private static let phoneToHead = simd_quatf(
        simd_float3x3(
            columns: (
                SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 1, 0)
            )))

    public init(reference: simd_quatf, camera: simd_quatf) {
        alignment = (camera * Self.phoneToHead * reference.inverse).normalized
    }

    public func ray(orientation: simd_quatf) -> PointerRay? {
        PointerRay(direction: (alignment * orientation).act(SIMD3<Float>(0, 1, 0)))
    }
}

/// The demo panel in the 3D scene and its rows.
public struct DemoPanel {
    public static let depth: Float = 1.5
    public static let width: Float = 0.9
    public static let height: Float = 0.64
    public static let contentTop: Float = 0.22
    public static let contentBottom: Float = -0.26
    public static let rowHeight: Float = 0.16
    public static let rowCount = 20
    public private(set) var counts = [Int](repeating: 0, count: rowCount)
    public private(set) var scrollOffset: Float = 0
    public private(set) var lastSelected: Int?
    public private(set) var scrolling = false

    public init() {}

    public static func intersection(_ ray: PointerRay) -> SIMD3<Float>? {
        guard ray.direction.z < -0.0001 else {
            return nil
        }
        let distance = -depth / ray.direction.z
        return ray.direction * distance
    }

    public func hit(_ ray: PointerRay) -> Int? {
        guard let point = Self.intersection(ray), abs(point.x) <= 0.4,
            point.y <= Self.contentTop, point.y > Self.contentBottom
        else {
            return nil
        }
        let index = Int(floor((Self.contentTop - point.y) / Self.rowHeight + scrollOffset))
        return (0..<Self.rowCount).contains(index) ? index : nil
    }

    @discardableResult
    public mutating func select(_ ray: PointerRay?) -> Int? {
        guard let ray, let index = hit(ray) else {
            return nil
        }
        counts[index] += 1
        lastSelected = index
        return index
    }

    public mutating func beginScroll(_ ray: PointerRay?) {
        scrolling = ray.flatMap { hit($0) } != nil
    }

    public mutating func scroll(deltaPoints: Float) {
        guard scrolling, deltaPoints.isFinite else {
            return
        }
        scrollOffset = min(max(scrollOffset - deltaPoints / 60, 0), Float(Self.rowCount - 3))
    }

    public mutating func endScroll() {
        scrolling = false
    }
}

/// The demo panel and the current pointer ray for one frame.
public struct InteractionFrame {
    public var panel: DemoPanel
    public var ray: PointerRay?
    public init(panel: DemoPanel, ray: PointerRay?) {
        self.panel = panel
        self.ray = ray
    }
}

/// Transfers a world-frame phone rotation into the glasses' Y-up scene.
public struct SpatialPhoneAim {
    private let reference: simd_quatf
    private let worldToScene: simd_quatf
    private let baseline: SIMD3<Float>

    public init(reference: simd_quatf, target: simd_quatf) {
        self.reference = reference
        baseline = target.act(SIMD3<Float>(0, 0, -1))
        let alongTop = reference.act(SIMD3<Float>(0, 1, 0))
        let alongBack = reference.act(SIMD3<Float>(0, 0, -1))
        let point = abs(alongTop.z) < 0.8 ? alongTop : alongBack
        let heading = atan2(point.y, point.x)
        let targetHeading = atan2(-baseline.x, -baseline.z)
        let removePhoneHeading = simd_quatf(angle: -heading, axis: SIMD3<Float>(0, 0, 1))
        let matchGlassesHeading = simd_quatf(angle: targetHeading, axis: SIMD3<Float>(0, 1, 0))
        worldToScene = (matchGlassesHeading * simd_quatf(SceneMath.basis) * removePhoneHeading).normalized
    }

    public func ray(orientation: simd_quatf) -> PointerRay? {
        let delta = worldToScene * (orientation * reference.inverse) * worldToScene.inverse
        return PointerRay(direction: delta.act(baseline))
    }
}
