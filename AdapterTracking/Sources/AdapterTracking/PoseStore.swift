import Foundation
import QuartzCore
import simd

/// Keeps the latest poses and detects gaps and stalled tracking.
public final class PoseStore {
    private let lock = NSLock()
    private var latest: TimedPose?
    private var gaps: [PoseGap] = []
    private var gapSequence = 0

    private var beforeGap: TimedPose?
    private var resumed: PoseResumption?
    private var events: [PoseTraceEvent] = []
    private var eventSequence = 0
    private var identicalRun: (first: TimedPose, count: Int)?
    private var recentArrivals: [TimeInterval] = []

    public init() {}

    public func reset() {
        lock.lock()
        finishIdenticalRun()
        latest = nil
        beforeGap = nil
        resumed = nil
        recentArrivals.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    @discardableResult
    func update(_ pose: AdapterPose, arrivalTime: TimeInterval, connection: Int = 0) -> TimedPose {
        lock.lock()
        defer {
            lock.unlock()
        }
        var velocity = SIMD3<Float>.zero
        if let previous = latest, previous.connection == connection {
            let ticks = pose.deviceMilliseconds &- previous.pose.deviceMilliseconds
            let deviceElapsedSeconds = Double(ticks) / 1000
            let arrivalInterval = arrivalTime - previous.arrivalTime
            // UInt32 wrap is valid, but a backwards jump is not a long forward gap.
            let deviceInterval = ticks < UInt32.max / 2 ? deviceElapsedSeconds : nil
            let shortGap = arrivalInterval >= 0.1 || (deviceInterval ?? 0) >= 0.1
            if shortGap || deviceInterval == nil {
                gapSequence += 1
                gaps.append(
                    PoseGap(
                        sequence: gapSequence, connection: connection, receivedAt: arrivalTime,
                        arrivalInterval: arrivalInterval, deviceInterval: deviceInterval))
                if gaps.count > 128 {
                    gaps.removeFirst()
                }
            }
            if shortGap {
                beforeGap = previous
                resumed = PoseResumption(connection: connection, receivedAt: arrivalTime, orientationChangedAt: nil)
                let same = pose.quaternionBits == previous.pose.quaternionBits
                append(
                    """
                    First pose after gap: connection \(connection), tick \(pose.deviceMilliseconds), q \
                    \(format(pose)); pre-gap quaternion bits identical: \(same)
                    """,
                    at: arrivalTime)
            }
            if let reference = beforeGap, !pose.sameQuaternion(as: reference.pose), let resume = resumed {
                let delta =
                    PoseMath.axisAngle(reference.pose.orientation.inverse * pose.orientation).radians * 180 / .pi
                append(
                    """
                    Pose changed after gap: connection \(connection), tick \(pose.deviceMilliseconds), Δ \
                    \(String(format:"%.5f",delta))°
                    """,
                    at: arrivalTime)
                resumed = PoseResumption(
                    connection: connection, receivedAt: resume.receivedAt, orientationChangedAt: arrivalTime)
                beforeGap = nil
            }
            if !shortGap, deviceInterval != nil, pose.sameOrientationPayload(as: previous.pose) {
                var run = identicalRun ?? (previous, 1)
                run.count += 1
                identicalRun = run
                if run.count == 12 {
                    append(
                        """
                        Bit-identical orientation run reached 12: start \
                        \(String(format:"%.3f",run.first.arrivalTime)), tick \(run.first.pose.deviceMilliseconds), \
                        connection \(connection)
                        """,
                        at: arrivalTime)
                }
            } else {
                finishIdenticalRun()
            }
            if deviceElapsedSeconds >= 0.005, deviceElapsedSeconds <= 0.1 {
                let change = PoseMath.axisAngle(previous.pose.orientation.inverse * pose.orientation)
                let measured = change.axis * min(change.radians / Float(deviceElapsedSeconds), 12)
                velocity = previous.angularVelocity * 0.5 + measured * 0.5
            }
        } else {
            finishIdenticalRun()
            beforeGap = nil
            resumed = nil
        }
        recentArrivals.append(arrivalTime)
        if let cutoff = recentArrivals.firstIndex(where: { $0 > arrivalTime - 1 }), cutoff > 0 {
            recentArrivals.removeFirst(cutoff)
        }
        let result = TimedPose(pose: pose, arrivalTime: arrivalTime, angularVelocity: velocity, connection: connection)
        latest = result
        return result
    }

    private func finishIdenticalRun() {
        if let run = identicalRun, run.count >= 12, let end = latest {
            append(
                """
                Bit-identical orientation run ended: \(run.count) packets in \
                \(String(format:"%.3f",end.arrivalTime-run.first.arrivalTime)) s, ending tick \
                \(end.pose.deviceMilliseconds)
                """,
                at: end.arrivalTime)
        }
        identicalRun = nil
    }

    func recordTrace(_ message: String, at time: TimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer {
            lock.unlock()
        }
        append(message, at: time)
    }
    private func append(_ message: String, at time: TimeInterval) {
        eventSequence += 1
        events.append(PoseTraceEvent(sequence: eventSequence, time: time, message: message))
        if events.count > 384 {
            events.removeFirst()
        }
    }
    private func format(_ pose: AdapterPose) -> String {
        let q = pose.orientation.vector
        return [q.x, q.y, q.z, q.w].map { String(format: "%.6f", $0) }.joined(separator: ",")
    }

    public func receiveCount(at now: TimeInterval) -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recentArrivals.lazy.filter { $0 > now - 1 && $0 <= now }.count
    }

    public func snapshot() -> TimedPose? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return latest
    }

    public func snapshot(afterGap cursor: Int, afterEvent eventCursor: Int = .max) -> (
        sample: TimedPose?, gaps: [PoseGap], resumption: PoseResumption?, events: [PoseTraceEvent]
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }
        return (
            latest, gaps.last.map { $0.sequence > cursor } == true ? gaps.filter { $0.sequence > cursor } : [],
            resumed,
            events.last.map { $0.sequence > eventCursor } == true ? events.filter { $0.sequence > eventCursor } : []
        )
    }

    // Render loops supply CADisplayLink.targetTimestamp or their presentation clock.
    public func orientation(at displayTime: TimeInterval, extraPrediction: TimeInterval = 0) -> simd_quatf? {
        snapshot()?.orientation(at: displayTime, extraPrediction: extraPrediction)
    }
}
