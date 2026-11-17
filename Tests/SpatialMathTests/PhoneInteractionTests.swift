import XCTest
import simd
@testable import SpatialMath

final class PhoneInteractionTests: XCTestCase {
    private func ray(_ x: Float, _ y: Float) -> PointerRay {
        PointerRay(direction: SIMD3(x, y, -1.5))!
    }

    func testPhoneCalibrationAndPhysicalDirections() {
        let identity = SceneMath.identity
        let aim = PhoneAim(reference: identity, camera: identity)
        XCTAssertEqual(aim.ray(orientation: identity)!.direction.z, -1, accuracy: 0.00001)
        let right = simd_quatf(angle: -0.2, axis: SIMD3<Float>(0, 0, 1))
        XCTAssertGreaterThan(aim.ray(orientation: right)!.direction.x, 0.19)
        let up = simd_quatf(angle: 0.2, axis: SIMD3<Float>(1, 0, 0))
        XCTAssertGreaterThan(aim.ray(orientation: up)!.direction.y, 0.19)
    }

    func testArbitraryReferenceAimsAtCameraAndRollDoesNotMoveRay() {
        let reference =
            simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 0, 1)) * simd_quatf(angle: 0.2, axis: SIMD3<Float>(1, 0, 0))
        let camera = simd_quatf(angle: -0.3, axis: SIMD3<Float>(0, 1, 0))
        let aim = PhoneAim(reference: reference, camera: camera)
        let expected = camera.act(SIMD3<Float>(0, 0, -1))
        XCTAssertLessThan(simd_length(aim.ray(orientation: reference)!.direction - expected), 0.00001)
        let rolled = reference * simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 1, 0))
        XCTAssertLessThan(simd_length(aim.ray(orientation: rolled)!.direction - expected), 0.00001)
    }

    func testPanelSelectionRejectsMissesAndTracksCounts() {
        var panel = DemoPanel()
        XCTAssertEqual(panel.select(ray(0, 0.14)), 0)
        XCTAssertEqual(panel.select(ray(0, 0.14)), 0)
        XCTAssertEqual(panel.select(ray(0, -0.02)), 1)
        XCTAssertEqual(panel.counts[0], 2)
        XCTAssertEqual(panel.lastSelected, 1)
        XCTAssertNil(panel.select(ray(1, 0)))
        XCTAssertNil(panel.select(PointerRay(direction: SIMD3(0, 0, 1))))
        XCTAssertNil(PointerRay(direction: .zero))
    }

    func testScrollRequiresHitCapturesTargetAndClamps() {
        var panel = DemoPanel()
        panel.beginScroll(ray(1, 0))
        panel.scroll(deltaPoints: -100)
        XCTAssertEqual(panel.scrollOffset, 0)
        panel.beginScroll(ray(0, 0.14))
        panel.scroll(deltaPoints: -60)
        XCTAssertEqual(panel.hit(ray(0, 0.14)), 1)
        // Gesture keeps its original target even if aim changes after begin.
        panel.scroll(deltaPoints: -10000)
        XCTAssertEqual(panel.scrollOffset, 17)
        XCTAssertEqual(panel.hit(ray(0, -0.18)), 19)
        panel.endScroll()
        panel.scroll(deltaPoints: 10000)
        XCTAssertEqual(panel.scrollOffset, 17)
        panel.beginScroll(ray(0, 0.14))
        panel.scroll(deltaPoints: 10000)
        XCTAssertEqual(panel.scrollOffset, 0)
    }
}
