import Foundation
import simd

/// Field of view, eye separation, prediction and mounting correction for the glasses.
public struct SceneSettings: Codable {
    // 52-degree diagonal and 16:10, assuming a symmetric rectilinear projection.
    public var horizontalFOV = SceneMath.fieldOfView(diagonal: 52, aspect: 1.6).x
    public var verticalFOV = SceneMath.fieldOfView(diagonal: 52, aspect: 1.6).y
    public var eyeSeparationMillimeters: Float = 63
    public var predictionEnabled = false
    public var extraPredictionMilliseconds: Double = 0
    public var invertQuaternion = false
    public var tableOffset: [Float]?
    public var tableDate: String?

    public init() {}

    public var mountingOffset: simd_quatf {
        guard let stored = tableOffset, stored.count == 4, stored.allSatisfy(\.isFinite) else {
            return SceneMath.identity
        }
        let offset = simd_quatf(vector: SIMD4(stored[0], stored[1], stored[2], stored[3]))
        return offset.length > 0.001 ? offset.normalized : SceneMath.identity
    }

    public func selectedOrientation(_ raw: simd_quatf) -> simd_quatf {
        invertQuaternion ? raw.inverse : raw
    }

    public func bodyOrientation(_ raw: simd_quatf) -> simd_quatf {
        (selectedOrientation(raw) * mountingOffset).normalized
    }

    public mutating func calibrateTable(raw: simd_quatf, date: String) {
        let orientation = selectedOrientation(raw)
        // Remove only the table pose's tilt. Its arbitrary yaw is not a mounting offset.
        let correction = (orientation.inverse * SceneMath.heading(orientation)).normalized.vector
        tableOffset = [correction.x, correction.y, correction.z, correction.w]
        tableDate = date
    }

    public mutating func clearTable() {
        tableOffset = nil
        tableDate = nil
    }
}

/// Projection, camera and quaternion helpers.
public enum SceneMath {
    public static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
    // Exact proper signed permutation: adapter +X forward -> render -Z,
    // adapter +Y left -> render -X, adapter +Z up -> render +Y.
    public static let basis = simd_float3x3(
        columns: (
            SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0)
        ))
    private static let basisRotation = simd_quatf(basis)

    public static func fieldOfView(diagonal: Float, aspect: Float) -> SIMD2<Float> {
        let tangent = tan(diagonal * .pi / 360)
        let vertical = tangent / sqrt(1 + aspect * aspect)
        return SIMD2(2 * atan(vertical * aspect), 2 * atan(vertical)) * (180 / .pi)
    }

    // Heading uses physical forward +X, independent of the diagnostic Euler decomposition.
    public static func heading(_ orientation: simd_quatf) -> simd_quatf {
        let forward = orientation.act(SIMD3<Float>(1, 0, 0))
        guard hypot(forward.x, forward.y) > 0.0001 else {
            return identity
        }
        return simd_quatf(angle: atan2(forward.y, forward.x), axis: SIMD3<Float>(0, 0, 1))
    }

    public static func cameraOrientation(
        raw: simd_quatf, settings: SceneSettings,
        headingReference: simd_quatf
    ) -> simd_quatf {
        let adapter = headingReference.inverse * settings.bodyOrientation(raw)
        return (basisRotation * adapter * basisRotation.inverse).normalized
    }

    public static func axisAngle(_ rotation: simd_quatf) -> (axis: SIMD3<Float>, degrees: Float) {
        let normalized = rotation.normalized
        let positive = normalized.real < 0 ? simd_quatf(vector: -normalized.vector) : normalized
        let length = simd_length(positive.imag)
        guard length > 0.000001 else {
            return (.zero, 0)
        }
        return (positive.imag / length, 2 * atan2(length, positive.real) * 180 / .pi)
    }

    // Right-handed camera, forward -Z, Metal clip-space depth 0...1.
    public static func projection(
        horizontal: Float, vertical: Float,
        near: Float = 0.05, far: Float = 2000
    ) -> simd_float4x4 {
        let horizontalRadians = min(max(horizontal, 10), 120) * .pi / 180
        let verticalRadians = min(max(vertical, 10), 100) * .pi / 180
        let z = far / (near - far)
        return simd_float4x4(
            columns: (
                SIMD4(1 / tan(horizontalRadians / 2), 0, 0, 0),
                SIMD4(0, 1 / tan(verticalRadians / 2), 0, 0),
                SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)
            ))
    }

    public static func view(orientation: simd_quatf, eyeOffset: Float) -> simd_float4x4 {
        // Both cameras are parallel. Eye separation rotates with the head.
        let rotation = simd_float3x3(orientation.inverse)
        let eye = orientation.act(SIMD3<Float>(eyeOffset, 0, 0))
        let translation = -(rotation * eye)
        return simd_float4x4(
            columns: (
                SIMD4(rotation.columns.0, 0), SIMD4(rotation.columns.1, 0),
                SIMD4(rotation.columns.2, 0), SIMD4(translation, 1)
            ))
    }
}
