import AdapterTracking
import Foundation
import SpatialMath
import simd

/// Records the transforms handed to UIKit. It does not measure compositor output or
/// the wearer's physical head pose. All timestamps share the Core Animation clock.
final class BrowserDriftLog {
    private struct Center {
        let at: Double
        let yaw: Float?
        let tilt: Float
        let placement: Int
        let connection: Int
    }
    private struct Residual {
        let points: Float
        let degrees: Float
    }
    private struct Row {
        let at: Double
        let text: String
        let residual: Residual?
    }
    private struct Projection {
        let center: SIMD2<Float>
        let roll: Float
    }

    private let span: Double = 1200
    private var rows: [Row] = []
    private var events: [(at: Double, text: String)] = []
    private var previousCenter: Center?
    private var latestCenter: Center?
    private var anchorMoved = false
    private var movedBetweenCenters = false

    func needsRow(at now: Double) -> Bool {
        rows.last.map { now - $0.at >= 1 } ?? true
    }
    func event(_ text: String, at now: Double) {
        events.append((now, text))
        if events.count > 512 {
            events.removeFirst(events.count - 512)
        }
    }
    func markAnchorChange() {
        if latestCenter != nil {
            anchorMoved = true
        }
    }

    func recenter(
        at now: Double, sample: TimedPose, elevation: Float, before: simd_quatf, after: simd_quatf, placement: Int
    ) {
        let orientation = sample.pose.orientation
        let yaw = Self.yaw(orientation)
        let tilt = Self.tilt(orientation)
        previousCenter = latestCenter
        latestCenter = Center(at: now, yaw: yaw, tilt: tilt, placement: placement, connection: sample.connection)
        movedBetweenCenters = anchorMoved
        anchorMoved = false
        event(
            """
            Recenter applied: connection \(sample.connection), tick \(sample.pose.deviceMilliseconds), placement \
            \(placement) | raw \(Self.quaternion(orientation)) | yaw \(Self.f(yaw))°, tilt \(Self.f(tilt))°, panel elevation \
            \(Self.f(elevation))° | anchor \(Self.quaternion(before)) → \(Self.quaternion(after))
            """,
            at: now)
    }

    func row(
        at now: Double, pose: BrowserPoseFrame, live: Bool, anchor: simd_quatf, placement: Int,
        phase: WorkspacePlacement.Phase, mode: PanelAnchorMode, prediction: Bool, panel: Int, receiveCount: Int,
        applied: simd_float4x4?, expected: simd_float4x4?
    ) {
        let sample = pose.sample
        let raw = sample?.pose.orientation
        let packetEuler = sample?.pose.packetEuler
        let actual = applied.flatMap(Self.project)
        let reference = expected.flatMap(Self.project)
        let residual = actual.flatMap { actualProjection in
            reference.map { referenceProjection in
                Residual(
                    points: simd_distance(actualProjection.center, referenceProjection.center),
                    degrees: abs(Self.wrap(actualProjection.roll - referenceProjection.roll)))
            }
        }
        // Heading reference and raw yaw both use the adapter's +Z up convention.
        let date = Self.d(now, 3)
        let age = sample.map { Self.d((now - $0.arrivalTime) * 1000, 1) } ?? ""
        let state = [
            sample.map { String($0.connection) } ?? "", sample.map { String($0.pose.deviceMilliseconds) } ?? "",
            age, live ? "1" : "0"
        ]
        let angles = [
            Self.f(packetEuler?.x), Self.f(packetEuler?.y), Self.f(packetEuler?.z),
            Self.f(raw.flatMap(Self.yaw)), Self.f(raw.map(Self.tilt))
        ]
        let workspace = [
            String(placement), String(describing: phase), mode.rawValue,
            Self.f(pose.heading.flatMap(Self.yaw)), prediction ? "1" : "0", String(panel)
        ]
        let text =
            ([date] + state + [String(receiveCount), Self.quaternion(raw)] + angles + [Self.quaternion(anchor)]
            + workspace + [Self.triple(actual), Self.triple(reference)]).joined(separator: ",")
        rows.append(Row(at: now, text: text, residual: residual))
        if rows.count > 1200 {
            rows.removeFirst(rows.count - 1200)
        }
    }

    var summary: String {
        let now = CACurrentMediaTime()
        let recent = rows.filter { now - $0.at <= span }
        let points = recent.compactMap { $0.residual?.points }.max()
        let degrees = recent.compactMap { $0.residual?.degrees }.max()
        let out =
            """
            Largest sampled projection difference (last 20m): \(Self.f(points,3)) pt, \(Self.f(degrees,3))° \
            (\(recent.filter { $0.residual != nil }.count) comparable rows)
            """
        guard let first = previousCenter, let last = latestCenter else {
            return "Drift: need two applied Recenters.\n" + out
        }
        let yaw = last.yaw.flatMap { end in first.yaw.map { Self.wrap(end - $0) } }
        let extraPlacements = last.placement != (first.placement &+ 1)
        let link =
            first.connection == last.connection
            ? "" : "; Bluetooth reconnected, so orientations may use different references"
        let summary = """
            Drift between last two applied Recenters (\(Self.d(last.at-first.at,1)) s): raw yaw \(Self.f(yaw))°, tilt \
            from adapter up \(Self.f(last.tilt-first.tilt))°; intervening anchor change: \
            \(movedBetweenCenters ? "yes" : "no"), intervening placement: \(extraPlacements ? "yes" : "no")\(link).\n
            """
        return summary + out
    }

    func table(at now: Double) -> String {
        let eventText = events.filter { now - $0.at <= span }.sorted { $0.at < $1.at }
            .map { "\(Self.d($0.at,3)) \($0.text)" }.joined(separator: "\n")
        let csv = rows.filter { now - $0.at <= span }.map(\.text).joined(separator: "\n")
        return """
            Drift events (monotonic seconds)
            \(eventText)

            Drift samples (one per second while rendering; values absent when unavailable)
            time_s,connection,tick_ms,age_ms,live,packets_last_second,raw_x,raw_y,raw_z,raw_w,pkt_a0_deg,pkt_a1_deg,pkt_a2_deg,raw_yaw_deg,raw_tilt_deg,anchor_x,anchor_y,anchor_z,anchor_w,placement,phase,mode,heading_reference_deg,prediction,panel,applied_x_pt,applied_y_pt,applied_roll_deg,recomputed_x_pt,recomputed_y_pt,recomputed_roll_deg
            \(csv)
            """
    }

    private static func project(_ transform: simd_float4x4) -> Projection? {
        func point(_ x: Float) -> SIMD2<Float>? {
            let projected = transform * SIMD4(x, 312.5, 0, 1)
            guard projected.w > 0.04 else {
                return nil
            }
            let xy = SIMD2(projected.x, projected.y) / projected.w
            return xy.x.isFinite && xy.y.isFinite ? xy : nil
        }
        guard let center = point(500), let left = point(400), let right = point(600) else {
            return nil
        }
        let direction = right - left
        guard simd_length(direction) > 0.001 else {
            return nil
        }
        return Projection(center: center, roll: atan2(direction.y, direction.x) * 180 / .pi)
    }
    private static func yaw(_ orientation: simd_quatf) -> Float? {
        let forward = orientation.act(SIMD3<Float>(1, 0, 0))
        return hypot(forward.x, forward.y) > 0.01 ? atan2(forward.y, forward.x) * 180 / .pi : nil
    }
    private static func tilt(_ orientation: simd_quatf) -> Float {
        acos(min(1, max(-1, orientation.act(SIMD3<Float>(0, 0, 1)).z))) * 180 / .pi
    }
    private static func wrap(_ value: Float) -> Float {
        let whole = (value + 180).truncatingRemainder(dividingBy: 360)
        return (whole < 0 ? whole + 360 : whole) - 180
    }
    private static func d(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value)
    }
    private static func f(_ value: Float?, _ decimals: Int = 2) -> String {
        guard let value, value.isFinite else {
            return ""
        }
        return d(Double(value), decimals)
    }
    private static func quaternion(_ orientation: simd_quatf?) -> String {
        let components = [orientation?.vector.x, orientation?.vector.y, orientation?.vector.z, orientation?.vector.w]
        return components.map { f($0, 5) }.joined(separator: ",")
    }
    private static func triple(_ projection: Projection?) -> String {
        [projection?.center.x, projection?.center.y, projection?.roll].map { f($0, 2) }.joined(separator: ",")
    }
}
