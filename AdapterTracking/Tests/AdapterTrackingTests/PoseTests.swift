import XCTest
import simd
@testable import AdapterTracking

final class PoseTests: XCTestCase {
    private let z = SIMD3<Float>(0, 0, 1)

    func testExactCapturedStartupFrames() {
        let cases: [(StartupCommand, String)] = [
            (.prepare, "fffecce40c000069956878c0e71812020000"),
            (.identify, "fffef3d60c0000da516c78c0e71811020000"),
            (.startPose, "fffee2620d000037ec6f78c0e7181500000001")
        ]
        for (command, hex) in cases {
            var expected: [UInt8] = stride(from: 0, to: hex.count, by: 2).map {
                let start = hex.index(hex.startIndex, offsetBy: $0)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            expected += Array(repeating: 0, count: 64 - expected.count)
            let stamp = (0..<8).reduce(UInt64(0)) { $0 | UInt64(expected[6 + $1]) << (8 * $1) }
            XCTAssertEqual(command.encode(timestamp: stamp), Data(expected))
        }
    }

    func testPoseStoreKeepsEverySampleAndPredictsForward() {
        let store = PoseStore()
        let elapsed: Float = 0.016
        for i in 0...12 {
            let angle = Float(i) * elapsed
            store.update(
                AdapterPose(
                    orientation: simd_quatf(angle: angle, axis: z),
                    deviceMilliseconds: UInt32(i * 16)),
                arrivalTime: 10 + Double(angle))
        }
        XCTAssertEqual(store.snapshot()?.pose.deviceMilliseconds, 192)
        let future = store.orientation(at: 10.208)!
        let heading = AdapterPose.angles(for: future).x * .pi / 180
        XCTAssertEqual(heading, 0.208, accuracy: 0.001)
        let capped = store.orientation(at: 10.208, extraPrediction: 1)!
        XCTAssertEqual(AdapterPose.angles(for: capped).x * .pi / 180, 0.242, accuracy: 0.001)
        let stale = store.orientation(at: 11)!
        XCTAssertEqual(stale.vector, store.snapshot()!.pose.orientation.vector)
        store.reset()
        XCTAssertNil(store.snapshot())
    }

    func testGapRecoveryRequiresArrivalAndDeviceClockDiscontinuity() throws {
        let store = PoseStore()
        func packet(_ t: Double, _ tick: UInt32, _ connection: Int = 1) {
            store.update(
                AdapterPose(orientation: simd_quatf(angle: 0, axis: z), deviceMilliseconds: tick),
                arrivalTime: t, connection: connection)
        }
        packet(0, 100)
        // A pause in reading the snapshot is not a pause in the receive path.
        for i in 1...2000 {
            packet(Double(i) * 0.016, 100 + UInt32(i) * 16)
        }
        XCTAssertTrue(store.snapshot(afterGap: 0).gaps.isEmpty)
        packet(53, 32116)
        let paused = try XCTUnwrap(store.snapshot(afterGap: 0).gaps.last)
        XCTAssertFalse(paused.warrantsPlacementRecovery)
        XCTAssertEqual(paused.arrivalInterval, 21, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(paused.deviceInterval), 0.016, accuracy: 0.001)
        packet(75, 54116)
        let realGap = try XCTUnwrap(store.snapshot(afterGap: paused.sequence).gaps.last)
        XCTAssertTrue(realGap.warrantsPlacementRecovery)
        XCTAssertEqual(realGap.receivedAt, 75)
        packet(101, 22, 2)
        XCTAssertEqual(store.snapshot()?.connection, 2)
        XCTAssertTrue(store.snapshot(afterGap: realGap.sequence).gaps.isEmpty)
    }

    func testCounterWrapIsContinuousButBackwardResetDoesNotRecenter() throws {
        let store = PoseStore()
        func packet(_ t: Double, _ tick: UInt32) {
            store.update(
                AdapterPose(orientation: simd_quatf(angle: 0, axis: z), deviceMilliseconds: tick), arrivalTime: t)
        }
        packet(1, UInt32.max - 7)
        packet(1.016, 8)
        XCTAssertTrue(store.snapshot(afterGap: 0).gaps.isEmpty)
        packet(25, 4)
        let reset = try XCTUnwrap(store.snapshot(afterGap: 0).gaps.last)
        XCTAssertNil(reset.deviceInterval)
        XCTAssertFalse(reset.warrantsPlacementRecovery)
    }

    func testReceiveTraceDetectsResumedFrozenPayloadAndFirstRealChange() throws {
        let store = PoseStore()
        func packet(_ tick: UInt32, _ time: Double, _ angle: Float = 0) {
            store.update(
                AdapterPose(orientation: simd_quatf(angle: angle, axis: z), deviceMilliseconds: tick),
                arrivalTime: time, connection: 1)
        }
        packet(0, 0)
        packet(112, 0.112)
        var trace = store.snapshot(afterGap: 0, afterEvent: 0)
        XCTAssertEqual(trace.gaps.count, 1)
        XCTAssertEqual(trace.resumption?.receivedAt, 0.112)
        XCTAssertNil(trace.resumption?.orientationChangedAt)
        XCTAssertTrue(trace.events.contains { $0.message.contains("bits identical: true") })
        for i in 1...11 {
            packet(112 + UInt32(i) * 16, 0.112 + Double(i) * 0.016)
        }
        trace = store.snapshot(afterGap: 0, afterEvent: 0)
        XCTAssertTrue(trace.events.contains { $0.message.contains("reached 12") })
        XCTAssertNil(trace.resumption?.orientationChangedAt)
        packet(304, 0.304, 0.02)
        trace = store.snapshot(afterGap: 0, afterEvent: 0)
        XCTAssertEqual(trace.resumption?.orientationChangedAt, 0.304)
        XCTAssertTrue(trace.events.contains { $0.message.contains("12 packets") })
        XCTAssertEqual(store.receiveCount(at: 0.31), 14)
        XCTAssertEqual(store.receiveCount(at: 1.31), 0)
    }

    func testHeadingRecenterPreservesGravityAndAxisReadout() {
        let q =
            (simd_quatf(angle: 0.8, axis: z) * simd_quatf(angle: 0.3, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: -0.4, axis: SIMD3(0, 1, 0))).normalized
        let centered = PoseMath.headingReference(q).inverse * q
        XCTAssertEqual(simd_length(centered.inverse.act(z) - q.inverse.act(z)), 0, accuracy: 0.00001)
        XCTAssertEqual(AdapterPose.angles(for: centered).x, 0, accuracy: 0.001)
        let reference = simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 1, 0))
        let current = reference * simd_quatf(angle: 0.25, axis: SIMD3<Float>(1, 0, 0))
        let axis = PoseMath.axisAngle(reference.inverse * current)
        XCTAssertEqual(axis.axis.x, 1, accuracy: 0.0001)
        XCTAssertEqual(axis.radians, 0.25, accuracy: 0.0001)
    }
}
