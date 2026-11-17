import XCTest
import SpatialMath
import simd

final class WorkspacePlacementTests: XCTestCase {
    func testLooksDownThenSettlesWithoutJumpAndKeepsAnchorOnResume() {
        var placement = WorkspacePlacement()
        let x = SIMD3<Float>(1, 0, 0)
        let down = simd_quatf(angle: -0.65, axis: x)
        let level = simd_quatf(angle: 0.08, axis: x)
        for i in 0...10 {
            placement.update(camera: down, live: true, speed: 0, now: Double(i) / 10, mode: .world)
        }
        XCTAssertEqual(placement.phase, .settling)
        placement.update(camera: level, live: true, speed: 1, now: 1.1, mode: .world)
        for i in 12...16 {
            placement.update(camera: level, live: true, speed: 0, now: Double(i) / 10, mode: .world)
        }
        let preview = placement.anchor
        placement.update(camera: level, live: true, speed: 0, now: 1.8, mode: .world)
        XCTAssertEqual(placement.phase, .placed)
        XCTAssertEqual(preview.vector, placement.anchor.vector)
        placement.update(camera: down, live: false, speed: 0, now: 10, mode: .world)
        placement.update(camera: down, live: true, speed: 0, now: 11, mode: .world)
        XCTAssertEqual(placement.anchor.vector, preview.vector)
        placement.waitForTracking()
        XCTAssertEqual(placement.phase, .waiting)
        placement.update(camera: down, live: true, speed: 1, now: 12, mode: .world, force: true)
        XCTAssertEqual(placement.phase, .placed)
        XCTAssertEqual(placement.placementID, 2)
    }
    func testStartupPlacesEvenWhenPitchAndMotionNeverQualify() {
        var placement = WorkspacePlacement()
        let down = simd_quatf(angle: -0.7, axis: SIMD3<Float>(1, 0, 0))
        for tick in 0...21 {
            placement.update(camera: down, live: true, speed: 0.4, now: Double(tick) / 10, mode: .world)
        }
        XCTAssertEqual(placement.phase, .placed)
        XCTAssertEqual(placement.placementID, 1)
        placement.update(camera: SceneMath.identity, live: true, speed: 0, now: 2.2, mode: .world)
        XCTAssertGreaterThan(SceneMath.axisAngle(placement.relativeCamera(SceneMath.identity)).degrees, 30)
    }

    func testPlacementDeadlineWaitsForFreshPoseAndResetsOnReconnect() {
        var placement = WorkspacePlacement()
        let camera = SceneMath.identity
        placement.update(camera: camera, live: false, speed: 1, now: 0, mode: .world)
        placement.update(camera: camera, live: true, speed: 1, now: 10, mode: .world)
        XCTAssertEqual(placement.phase, .settling)
        placement.update(camera: camera, live: false, speed: 0, now: 12.1, mode: .world)
        XCTAssertEqual(placement.phase, .waiting)
        XCTAssertEqual(placement.placementID, 0)
        placement.update(camera: camera, live: true, speed: 1, now: 12.2, mode: .world)
        XCTAssertEqual(placement.phase, .placed)
        placement.waitForTracking()
        placement.update(camera: camera, live: true, speed: 1, now: 30, mode: .world)
        XCTAssertEqual(placement.phase, .settling)
        XCTAssertEqual(placement.placementID, 1)
    }
    func testFirstConnectionWaitsOutUnstablePoseButHasFifteenSecondCap() {
        var unstable = WorkspacePlacement()
        let pose = SceneMath.identity
        unstable.update(camera: pose, live: true, speed: 1, now: 10, mode: .world, firstPlacementOnConnection: true)
        unstable.update(camera: pose, live: true, speed: 1, now: 12.1, mode: .world, firstPlacementOnConnection: true)
        XCTAssertEqual(unstable.phase, .settling)
        unstable.update(camera: pose, live: true, speed: 1, now: 25, mode: .world, firstPlacementOnConnection: true)
        XCTAssertEqual(unstable.phase, .placed)

        var stable = WorkspacePlacement()
        for i in 0...5 {
            stable.update(
                camera: pose, live: true, speed: 0, now: Double(i) / 10, mode: .world, firstPlacementOnConnection: true)
        }
        XCTAssertEqual(stable.phase, .placed)
    }

    func testFirstConnectionWaitsForAdapterTiltToStopDrifting() {
        // Mirrors device logs: reported tilt slides toward gravity for seconds
        // after connecting while the head is still and angular speed reads low.
        var placement = WorkspacePlacement()
        let x = SIMD3<Float>(1, 0, 0)
        var tick = 0
        func step(_ degrees: Float) {
            placement.update(
                camera: simd_quatf(angle: degrees * .pi / 180, axis: x), live: true, speed: 0,
                now: Double(tick) / 60, mode: .world, firstPlacementOnConnection: true)
            tick += 1
        }
        // Drifting 3°/s for 4 s: must not place.
        for i in 0..<240 {
            step(40 - 3 * Float(i) / 60)
        }
        XCTAssertEqual(placement.phase, .settling)
        // Drift stops: places once the tilt has held still for half a second.
        for _ in 0..<40 {
            step(28)
        }
        XCTAssertEqual(placement.phase, .placed)
        // Later placements on the same connection are not held back by this check.
        placement.waitForTracking()
        for i in 0...6 {
            placement.update(camera: SceneMath.identity, live: true, speed: 0, now: 10 + Double(i) / 10, mode: .world)
        }
        XCTAssertEqual(placement.phase, .placed)
    }

    func testRecenterWaitsForActualOrientationThenPermitsAnUnchangedLivePose() {
        var waiting = RecenterRequest(dueAt: 10)
        XCTAssertEqual(waiting.step(now: 10, live: false, arrival: 9, resume: nil, unchanged: false), .pending)
        XCTAssertEqual(waiting.step(now: 12, live: true, arrival: 12, resume: 12, unchanged: true), .pending)
        XCTAssertTrue(waiting.waitedForUnchanged)
        XCTAssertEqual(waiting.step(now: 14.99, live: true, arrival: 14.99, resume: 12, unchanged: true), .pending)
        XCTAssertEqual(waiting.step(now: 15, live: true, arrival: 15, resume: 12, unchanged: false), .apply)

        var immediate = RecenterRequest(dueAt: 20)
        XCTAssertEqual(immediate.step(now: 20, live: true, arrival: 19.99, resume: nil, unchanged: false), .apply)
        XCTAssertFalse(immediate.waitedForUnchanged)
    }

    func testRecenterExpiresWithoutPacketsAndCannotWaitIndefinitelyAcrossGaps() {
        var request = RecenterRequest(dueAt: 20)
        XCTAssertEqual(request.step(now: 23, live: false, arrival: 19, resume: nil, unchanged: false), .expire)
        var late = RecenterRequest(dueAt: 0)
        XCTAssertEqual(late.step(now: 3.1, live: true, arrival: 3.1, resume: 3.1, unchanged: false), .expire)
        var repeated = RecenterRequest(dueAt: 0)
        XCTAssertEqual(repeated.step(now: 2.9, live: true, arrival: 2.9, resume: 2.8, unchanged: true), .pending)
        XCTAssertEqual(repeated.step(now: 6, live: true, arrival: 6, resume: 5.9, unchanged: true), .expire)
    }
}
