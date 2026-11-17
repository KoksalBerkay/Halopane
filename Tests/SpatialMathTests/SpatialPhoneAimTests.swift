import XCTest
import SpatialMath
import simd

final class SpatialPhoneAimTests: XCTestCase {
    func testFlatAndUprightGripsRespondToWorldYawAndPitch() throws {
        for angle: Float in [0, .pi / 2] {
            let q = simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0))
            let aim = SpatialPhoneAim(reference: q, target: SceneMath.identity)
            let resting = try XCTUnwrap(aim.ray(orientation: q))
            XCTAssertEqual(resting.direction, SIMD3<Float>(0, 0, -1))
            let yaw = try XCTUnwrap(aim.ray(orientation: simd_quatf(angle: 0.1, axis: SIMD3<Float>(0, 0, 1)) * q))
            let pitch = try XCTUnwrap(aim.ray(orientation: simd_quatf(angle: 0.1, axis: SIMD3<Float>(1, 0, 0)) * q))
            XCTAssertLessThan(yaw.direction.x, -0.09)
            XCTAssertEqual(yaw.direction.y, 0, accuracy: 0.001)
            XCTAssertGreaterThan(pitch.direction.y, 0.09)
            XCTAssertEqual(pitch.direction.x, 0, accuracy: 0.001)
        }
    }
}
