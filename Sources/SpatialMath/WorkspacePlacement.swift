import Foundation
import simd

/// Places the workspace in front of the user once tracking is stable, then keeps it there.
public struct WorkspacePlacement {
    public enum Phase: Equatable { case waiting, settling, placed }
    public private(set) var phase: Phase = .waiting
    public private(set) var anchor = SceneMath.identity
    public private(set) var placementID = 0
    private let maxSettlingTime: TimeInterval = 2
    private var firstLiveAt: TimeInterval?
    private var readySince: TimeInterval?
    private var previousTick: TimeInterval?
    private var follow = FollowAnchor()
    // The adapter's orientation can start far from gravity and slide back over
    // several seconds after connecting. On the first placement of a connection,
    // wait until the camera's up vector stops drifting (about 1 degree per second or less).
    private let tiltDriftLimit: Float = 0.5 * .pi / 180
    private let tiltSettleTime: TimeInterval = 0.5
    private var tiltReference: SIMD3<Float>?
    private var tiltSince: TimeInterval?
    public var isFollowing: Bool { follow.isMoving }

    public init() {}

    public mutating func waitForTracking() {
        phase = .waiting
        firstLiveAt = nil
        readySince = nil
        previousTick = nil
        tiltReference = nil
        tiltSince = nil
        follow.reset()
    }

    public mutating func update(
        camera: simd_quatf, live: Bool, speed: Float, now: TimeInterval,
        mode: PanelAnchorMode, force: Bool = false,
        followZone: Float = 22, followSpeed: Float = 5, firstPlacementOnConnection: Bool = false
    ) {
        let timeSinceLastUpdate = previousTick.map { now - $0 } ?? 0
        previousTick = now
        guard live else {
            if phase != .placed {
                phase = .waiting
                readySince = nil
                tiltReference = nil
                tiltSince = nil
            }
            return
        }
        if force || phase != .placed {
            if firstLiveAt == nil {
                firstLiveAt = now
            }
            let deadlineReached =
                firstLiveAt.map { now - $0 >= (firstPlacementOnConnection ? 15 : maxSettlingTime) } ?? false
            anchor = mode == .reclined ? camera : WebPanelMath.levelAnchor(lookingWith: camera)
            phase = .settling
            let forward = camera.act(SIMD3<Float>(0, 0, -1))
            var tiltSettled = true
            if firstPlacementOnConnection {
                let up = camera.act(SIMD3<Float>(0, 1, 0))
                if let reference = tiltReference, timeSinceLastUpdate <= 0.2,
                    simd_dot(reference, up) >= cos(tiltDriftLimit)
                {
                    // Still within the drift limit of the reference; keep timing.
                } else {
                    tiltReference = up
                    tiltSince = now
                }
                tiltSettled = tiltSince.map { now - $0 >= tiltSettleTime } ?? false
            }
            let suitable =
                speed < 10 * .pi / 180
                && (firstPlacementOnConnection || mode == .reclined || forward.y >= sin(-25 * Float.pi / 180))
            if !suitable || timeSinceLastUpdate > 0.2 {
                readySince = nil
            }
            if suitable && readySince == nil {
                readySince = now
            }
            if force || deadlineReached || (tiltSettled && readySince.map({ now - $0 >= 0.5 }) == true) {
                phase = .placed
                placementID &+= 1
                firstLiveAt = nil
                readySince = nil
                tiltReference = nil
                tiltSince = nil
                follow.reset()
            }
        } else if mode == .follow {
            anchor = follow.step(
                anchor: anchor, camera: camera, dt: Float(timeSinceLastUpdate), deadZoneDegrees: followZone,
                speed: followSpeed)
        }
    }

    public func relativeCamera(_ camera: simd_quatf) -> simd_quatf {
        phase == .waiting ? SceneMath.identity : (anchor.inverse * camera).normalized
    }
}

/// A Recenter scheduled after a countdown, waiting for live tracking.
public struct RecenterRequest {
    public enum Action: Equatable { case countdown, pending, apply, expire }
    public let dueAt: TimeInterval
    public var announcedWaiting = false
    public private(set) var waitedForUnchanged = false
    private var hadLivePacket = false

    public init(dueAt: TimeInterval) {
        self.dueAt = dueAt
    }

    public mutating func step(
        now: TimeInterval, live: Bool, arrival: TimeInterval?,
        resume: TimeInterval?, unchanged: Bool
    ) -> Action {
        guard now >= dueAt else {
            return .countdown
        }
        let deadline = dueAt + 3
        if live, now <= deadline, !unchanged {
            return .apply
        }

        // A packet that arrived while we were waiting counts even if the latest
        // display callback is later. Do not extend the wait indefinitely on new gaps.
        let window = dueAt...deadline
        if arrival.map(window.contains) == true || resume.map(window.contains) == true {
            hadLivePacket = true
        }
        if now >= deadline, !hadLivePacket {
            return .expire
        }
        if now >= deadline + 3 {
            return .expire
        }
        if live, !unchanged {
            return .apply
        }
        if live, unchanged {
            waitedForUnchanged = true
        }
        return .pending
    }
}
