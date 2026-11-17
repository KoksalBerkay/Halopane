import XCTest
import SpatialMath
import simd

final class FollowAnchorTests: XCTestCase {
    func testHoldsWithinDeadZoneThenConvergesWithoutOvershoot() {
        var spring = FollowAnchor()
        let up = SIMD3<Float>(0, 1, 0)
        let initial = SceneMath.identity
        let near = simd_quatf(angle: 0.2, axis: up)
        var anchor = spring.step(anchor: initial, camera: near, dt: 1 / 60, deadZoneDegrees: 22, speed: 5)
        XCTAssertEqual(anchor.vector, initial.vector)
        let far = simd_quatf(angle: 0.7, axis: up)
        var previous: Float = 41
        for _ in 0..<180 {
            anchor = spring.step(anchor: anchor, camera: far, dt: 1 / 60, deadZoneDegrees: 22, speed: 5)
            let error = SceneMath.axisAngle(anchor.inverse * far).degrees
            XCTAssertLessThanOrEqual(error, previous + 0.001)
            previous = error
        }
        XCTAssertLessThan(previous, 0.2)
    }
}
