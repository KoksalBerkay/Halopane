import Foundation
import CoreGraphics
import simd

/// Geometry for a screen in the glasses: size, placement and pointer hit testing.
public enum WebPanelMath {
    public static let sourceSize = SIMD2<Float>(1000, 625)
    public static let width: Float = 0.9
    public static let height: Float = 0.5625
    public static let depth: Float = 1.5

    // Convert trackpad travel into a vertical touch swipe inside the source view.
    // Keep the touch away from fixed headers and system gesture edges.
    public static func verticalTouchSwipe(from point: CGPoint, in bounds: CGRect, scrollDelta: Double)
        -> (start: CGPoint, end: CGPoint)?
    {
        guard bounds.contains(point), scrollDelta.isFinite, abs(scrollDelta) >= 26 else {
            return nil
        }
        let x = min(max(point.x, bounds.minX + bounds.width * 0.12), bounds.maxX - bounds.width * 0.12)
        let height = bounds.height
        let distance = min(max(CGFloat(abs(scrollDelta)), height * 0.23), height * 0.60)
        let top = bounds.minY + max(height * 0.23, min(point.y - bounds.minY - distance / 2, height * 0.90 - distance))
        let upper = CGPoint(x: x, y: top)
        let lower = CGPoint(x: x, y: top + distance)
        return scrollDelta > 0 ? (lower, upper) : (upper, lower)
    }

    // Aim the panel along gaze, with the panel's horizontal axis kept level.
    public static func levelAnchor(lookingWith camera: simd_quatf) -> simd_quatf {
        let forward = camera.act(SIMD3<Float>(0, 0, -1))
        let lateral = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        let right: SIMD3<Float>
        if simd_length_squared(lateral) > 0.000001 {
            right = simd_normalize(lateral)
        } else {
            let cameraRight = camera.act(SIMD3<Float>(1, 0, 0))
            right = simd_normalize(cameraRight - simd_dot(cameraRight, forward) * forward)
        }
        return simd_quatf(simd_float3x3(columns: (right, simd_cross(right, forward), -forward))).normalized
    }

    public static var sourceToWorld: simd_float4x4 {
        sourceToWorld(at: depth)
    }

    private static func sourceToWorld(at depth: Float) -> simd_float4x4 {
        simd_float4x4(
            columns: (
                SIMD4(width / sourceSize.x, 0, 0, 0),
                SIMD4(0, -height / sourceSize.y, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-width / 2, height / 2, -depth, 1)
            ))
    }

    public static func screenTransform(
        camera: simd_quatf, eyeOffset: Float,
        viewport: SIMD2<Float>, settings: SceneSettings, depth: Float = depth,
        screenOffset: SIMD2<Float> = .zero
    ) -> simd_float4x4 {
        let screen = simd_float4x4(
            columns: (
                SIMD4(viewport.x / 2, 0, 0, 0), SIMD4(0, -viewport.y / 2, 0, 0),
                SIMD4(0, 0, 1, 0), SIMD4(viewport.x / 2 + screenOffset.x, viewport.y / 2 + screenOffset.y, 0, 1)
            ))
        return screen * SceneMath.projection(horizontal: settings.horizontalFOV, vertical: settings.verticalFOV)
            * SceneMath.view(orientation: camera, eyeOffset: eyeOffset) * sourceToWorld(at: depth)
    }

    public static func point(for ray: PointerRay, topInset: Float = 0) -> SIMD2<Float>? {
        guard ray.direction.z < -0.0001 else {
            return nil
        }

        let rayScale = -depth / ray.direction.z
        let hit = ray.direction * rayScale
        let normalizedPoint = SIMD2(hit.x / width + 0.5, 0.5 - hit.y / height)
        let minimumY = -topInset / sourceSize.y

        guard normalizedPoint.x >= 0, normalizedPoint.x < 1,
            normalizedPoint.y >= minimumY, normalizedPoint.y < 1
        else {
            return nil
        }
        return normalizedPoint * sourceSize
    }
}
