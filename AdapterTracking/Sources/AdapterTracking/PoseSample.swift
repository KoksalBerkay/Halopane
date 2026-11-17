import Foundation
import simd

/// A pose with its arrival time and connection number.
public struct TimedPose {
    public let pose: AdapterPose
    public let arrivalTime: TimeInterval
    public let angularVelocity: SIMD3<Float>
    public let connection: Int

    public func orientation(at displayTime: TimeInterval, extraPrediction: TimeInterval = 0) -> simd_quatf {
        let age = displayTime - arrivalTime
        guard age >= 0, age < 0.1 else {
            return pose.orientation
        }
        let horizon = Float(min(max(age + extraPrediction, 0), 0.05))
        let speed = simd_length(angularVelocity)
        guard speed > 0.0001 else {
            return pose.orientation
        }
        let step = simd_quatf(angle: speed * horizon, axis: angularVelocity / speed)
        return (pose.orientation * step).normalized
    }
}

/// A pause in pose packets.
public struct PoseGap {
    public let sequence: Int
    public let connection: Int
    public let receivedAt: TimeInterval
    public let arrivalInterval: TimeInterval
    public let deviceInterval: TimeInterval?
    public var warrantsPlacementRecovery: Bool {
        arrivalInterval >= 20 && (deviceInterval ?? 0) >= 20
    }
}

/// The first pose after a gap.
public struct PoseResumption {
    public let connection: Int
    public let receivedAt: TimeInterval
    public let orientationChangedAt: TimeInterval?
}

/// A tracking event for the diagnostics log.
public struct PoseTraceEvent {
    public let sequence: Int
    public let time: TimeInterval
    public let message: String
}

public enum PoseMath {
    public static func axisAngle(_ rotation: simd_quatf) -> (axis: SIMD3<Float>, radians: Float) {
        let normalized = rotation.normalized
        let shortestRotation = normalized.real < 0 ? simd_quatf(vector: -normalized.vector) : normalized
        let length = simd_length(shortestRotation.imag)
        guard length > 0.000001 else {
            return (.zero, 0)
        }
        return (shortestRotation.imag / length, 2 * atan2(length, shortestRotation.real))
    }

    // Adapter Z is the provisional world-up axis. Removing heading preserves tilt.
    public static func headingReference(_ orientation: simd_quatf) -> simd_quatf {
        let forward = orientation.act(SIMD3<Float>(0, 1, 0))
        guard hypot(forward.x, forward.y) > 0.001 else {
            return simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        }
        return simd_quatf(angle: atan2(-forward.x, forward.y), axis: SIMD3(0, 0, 1))
    }
}
