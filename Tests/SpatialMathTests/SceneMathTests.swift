import XCTest
import simd
@testable import SpatialMath

final class SceneMathTests: XCTestCase {
    private let x = SIMD3<Float>(1, 0, 0)
    private let y = SIMD3<Float>(0, 1, 0)
    private let z = SIMD3<Float>(0, 0, 1)

    func testBasisAndPhysicalRotationSigns() {
        XCTAssertEqual(simd_determinant(SceneMath.basis), 1, accuracy: 0.00001)
        let settings = SceneSettings()
        let right = SceneMath.cameraOrientation(
            raw: simd_quatf(angle: -.pi / 6, axis: z), settings: settings, headingReference: SceneMath.identity)
        let nod = SceneMath.cameraOrientation(
            raw: simd_quatf(angle: .pi / 6, axis: y), settings: settings, headingReference: SceneMath.identity)
        let tilt = SceneMath.cameraOrientation(
            raw: simd_quatf(angle: .pi / 6, axis: x), settings: settings, headingReference: SceneMath.identity)
        XCTAssertGreaterThan(right.act(SIMD3<Float>(0, 0, -1)).x, 0.49)
        XCTAssertLessThan(nod.act(SIMD3<Float>(0, 0, -1)).y, -0.49)
        XCTAssertGreaterThan(tilt.act(y).x, 0.49)
    }

    func testTableCorrectionOnBodySideAndHeadingPreservesGravity() {
        var settings = SceneSettings()
        let yaw = simd_quatf(angle: 0.7, axis: z)
        let mounting = simd_quatf(angle: 0.35, axis: y)
        let table = yaw * mounting
        settings.calibrateTable(raw: table, date: "test")
        XCTAssertLessThan(SceneMath.axisAngle(yaw.inverse * settings.bodyOrientation(table)).degrees, 0.001)
        // The same constant must level another yaw, without erasing motion.
        let nextYaw = simd_quatf(angle: -0.6, axis: z)
        let corrected = settings.bodyOrientation(nextYaw * mounting)
        XCTAssertLessThan(SceneMath.axisAngle(nextYaw.inverse * corrected).degrees, 0.001)
        let tilted = nextYaw * simd_quatf(angle: 0.2, axis: x)
        let centered = SceneMath.heading(tilted).inverse * tilted
        XCTAssertLessThan(simd_length(centered.inverse.act(z) - tilted.inverse.act(z)), 0.00001)
    }

    func testBodyVersusWorldAxisForTurnFromPitchedReference() {
        let reference = simd_quatf(angle: 0.35, axis: y)
        let current = simd_quatf(angle: -0.6, axis: z) * reference
        let body = SceneMath.axisAngle(reference.inverse * current)
        let world = SceneMath.axisAngle(current * reference.inverse)
        XCTAssertGreaterThan(abs(body.axis.x), 0.3)
        XCTAssertEqual(world.axis.z, -1, accuracy: 0.00001)
        XCTAssertEqual(world.degrees, 0.6 * 180 / .pi, accuracy: 0.0001)
    }

    func testProjectionEdgesClipDepthAndStereoDisparity() {
        let settings = SceneSettings()
        XCTAssertEqual(settings.horizontalFOV, 44.9, accuracy: 0.15)
        XCTAssertEqual(settings.verticalFOV, 29.0, accuracy: 0.15)
        let projection = SceneMath.projection(horizontal: settings.horizontalFOV, vertical: settings.verticalFOV)
        let horizontalEdge = projection * SIMD4<Float>(tan(settings.horizontalFOV * .pi / 360) * 1.5, 0, -1.5, 1)
        XCTAssertEqual(horizontalEdge.x / horizontalEdge.w, 1, accuracy: 0.00001)
        let near = projection * SIMD4<Float>(0, 0, -0.05, 1)
        let far = projection * SIMD4<Float>(0, 0, -2000, 1)
        XCTAssertEqual(near.z / near.w, 0, accuracy: 0.00001)
        XCTAssertEqual(far.z / far.w, 1, accuracy: 0.00001)
        let point = SIMD4<Float>(0, 0, -1.5, 1)
        let left = projection * SceneMath.view(orientation: SceneMath.identity, eyeOffset: -0.0315) * point
        let right = projection * SceneMath.view(orientation: SceneMath.identity, eyeOffset: 0.0315) * point
        XCTAssertGreaterThan(left.x / left.w, 0)
        XCTAssertLessThan(right.x / right.w, 0)
        XCTAssertEqual(left.x / left.w, -right.x / right.w, accuracy: 0.00001)
    }
}
