import Foundation
import simd

/// How the workspace stays placed: fixed in the room, following the head, or reclined.
public enum PanelAnchorMode: String, CaseIterable, Identifiable {
    case world = "World-fixed", follow = "Follow", reclined = "Reclined"
    public var id: String { rawValue }
}

/// Critically damped response in the rotation-vector frame of a captured anchor.
public struct FollowAnchor {
    private var base: simd_quatf?
    private var displacement = SIMD3<Float>.zero
    private var velocity = SIMD3<Float>.zero
    public var isMoving: Bool { base != nil }
    public init() {}
    public mutating func reset() {
        self = Self()
    }

    public mutating func step(
        anchor: simd_quatf, camera: simd_quatf, dt: Float,
        deadZoneDegrees: Float, speed: Float
    ) -> simd_quatf {
        let forward = SIMD3<Float>(0, 0, -1)
        let gaze = camera.act(forward)
        let alignment = min(1, max(-1, simd_dot(anchor.act(forward), gaze)))
        if base == nil {
            guard acos(alignment) > deadZoneDegrees * .pi / 180 else {
                return anchor
            }
            base = anchor
        }
        guard let base else {
            return anchor
        }
        let level = WebPanelMath.levelAnchor(lookingWith: camera)
        let change = SceneMath.axisAngle(base.inverse * level)
        let target = change.axis * (change.degrees * .pi / 180)
        let stepTime = min(max(dt, 0), 0.05)
        let frequency = max(1, speed)
        let decay = exp(-frequency * stepTime)
        let error = displacement - target
        let rate = velocity + frequency * error
        displacement = target + (error + rate * stepTime) * decay
        velocity = (velocity - frequency * rate * stepTime) * decay
        let length = simd_length(displacement)
        if simd_length(displacement - target) < 0.002 && simd_length(velocity) < 0.01 {
            reset()
            return level
        }
        guard length > 0.000001 else {
            return base
        }
        return (base * simd_quatf(angle: length, axis: displacement / length)).normalized
    }
}
