import CoreGraphics
import XCTest
import simd
@testable import SpatialMath
final class WebPanelTests: XCTestCase {
    func testVerticalTouchSwipeLeavesHeaderClearInBothDirections() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 625)
        let aim = CGPoint(x: 8, y: 12)
        let down = try XCTUnwrap(WebPanelMath.verticalTouchSwipe(from: aim, in: bounds, scrollDelta: 450))
        let up = try XCTUnwrap(WebPanelMath.verticalTouchSwipe(from: aim, in: bounds, scrollDelta: -450))
        XCTAssertTrue(bounds.contains(down.start))
        XCTAssertTrue(bounds.contains(down.end))
        XCTAssertGreaterThan(down.start.y, down.end.y)
        XCTAssertGreaterThanOrEqual(down.end.y, bounds.height * 0.23)
        XCTAssertGreaterThan(down.end.x, aim.x)
        XCTAssertEqual(up.start, down.end)
        XCTAssertEqual(up.end, down.start)
        XCTAssertNil(WebPanelMath.verticalTouchSwipe(from: aim, in: bounds, scrollDelta: 8))
    }

    func testCenterProjectionAndRayHitAgree() {
        let settings = SceneSettings()
        let camera = SceneMath.identity
        let transform = WebPanelMath.screenTransform(
            camera: camera, eyeOffset: 0, viewport: SIMD2(1920, 1200), settings: settings)
        let center = transform * SIMD4<Float>(500, 312.5, 0, 1)
        XCTAssertEqual(center.x / center.w, 960, accuracy: 0.001)
        XCTAssertEqual(center.y / center.w, 600, accuracy: 0.001)
        let hit = WebPanelMath.point(for: PointerRay(direction: SIMD3(0, 0, -1))!)!
        XCTAssertEqual(hit.x, 500, accuracy: 0.001)
        XCTAssertEqual(hit.y, 312.5, accuracy: 0.001)
        XCTAssertNil(WebPanelMath.point(for: PointerRay(direction: SIMD3(1, 0, -1))!))
    }
    func testLevelAnchorCentersPitchedAndRolledGaze() throws {
        let z = SIMD3<Float>(0, 0, -1)
        let viewport = SIMD2<Float>(1920, 1200)
        for pitch: Float in [-0.35, 0.3] {
            let camera =
                simd_quatf(angle: 0.55, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0)) * simd_quatf(angle: 0.3, axis: z)
            let anchor = WebPanelMath.levelAnchor(lookingWith: camera)
            XCTAssertEqual(anchor.act(SIMD3<Float>(1, 0, 0)).y, 0, accuracy: 0.0001)
            let relative = anchor.inverse * camera
            let transform = WebPanelMath.screenTransform(
                camera: relative, eyeOffset: 0,
                viewport: viewport, settings: SceneSettings())
            let center = transform * SIMD4<Float>(500, 312.5, 0, 1)
            XCTAssertEqual(center.x / center.w, 960, accuracy: 0.001)
            XCTAssertEqual(center.y / center.w, 600, accuracy: 0.001)
            let gaze = try XCTUnwrap(PointerRay(direction: relative.act(z)))
            let hit = try XCTUnwrap(WebPanelMath.point(for: gaze))
            XCTAssertEqual(hit.x, 500, accuracy: 0.001)
            XCTAssertEqual(hit.y, 312.5, accuracy: 0.001)
        }
    }
    func testProjectedQuadUsesSameWorldGeometryAfterTurn() {
        let camera = simd_quatf(angle: -0.2, axis: SIMD3<Float>(0, 1, 0))
        let settings = SceneSettings()
        let transform = WebPanelMath.screenTransform(
            camera: camera, eyeOffset: 0.0315, viewport: SIMD2(1920, 1200), settings: settings)
        let source = SIMD4<Float>(120, 240, 0, 1)
        let world = WebPanelMath.sourceToWorld * source
        let clip =
            SceneMath.projection(horizontal: settings.horizontalFOV, vertical: settings.verticalFOV)
            * SceneMath.view(orientation: camera, eyeOffset: 0.0315) * world
        let screen = transform * source
        XCTAssertEqual(screen.x / screen.w, (clip.x / clip.w + 1) * 960, accuracy: 0.001)
        XCTAssertEqual(screen.y / screen.w, (1 - clip.y / clip.w) * 600, accuracy: 0.001)
    }
    func testFullScreenFitsVisibleAreaWithoutRelayoutAndExitUsesTheNewCamera() {
        let settings = SceneSettings()
        let viewport = SIMD2<Float>(1920, 1200)
        let visible = VisibleArea().rect(in: CGSize(width: 1920, height: 1200))
        for content in [
            CGRect(x: 0, y: 0, width: 1000, height: 625), CGRect(x: 0, y: 31.25, width: 1000, height: 562.5)
        ] {
            let fit = FullScreenGeometry(viewport: viewport, visible: visible, settings: settings, content: content)
            let shifted = simd_quatf(angle: 40 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
            let screen = fit.transform(camera: shifted, blend: 1, viewport: viewport, settings: settings)
            func project(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
                let p = screen * SIMD4(Float(x), Float(y), 0, 1)
                return SIMD2(p.x, p.y) / p.w
            }
            let center = project(content.midX, content.midY)
            let a = project(content.minX, content.minY), b = project(content.maxX, content.maxY)
            XCTAssertEqual(center.x, Float(visible.midX), accuracy: 0.01)
            XCTAssertEqual(center.y, Float(visible.midY), accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(a.x, Float(visible.minX) - 0.01)
            XCTAssertGreaterThanOrEqual(a.y, Float(visible.minY) - 0.01)
            XCTAssertLessThanOrEqual(b.x, Float(visible.maxX) + 0.01)
            XCTAssertLessThanOrEqual(b.y, Float(visible.maxY) + 0.01)
            let xFill = (b.x - a.x) / Float(visible.width), yFill = (b.y - a.y) / Float(visible.height)
            XCTAssertEqual(max(xFill, yFill), 1, accuracy: 0.001)

            let room = WebPanelMath.screenTransform(
                camera: shifted, eyeOffset: 0, viewport: viewport, settings: settings)
            let exit = fit.transform(camera: shifted, blend: 0, viewport: viewport, settings: settings)
            for column in 0..<4 {
                XCTAssertLessThan(simd_length(room[column] - exit[column]), 0.002)
            }
        }
    }

    func testFullScreenTransitionReversesWithoutJump() {
        var transition = PanelExpansion()
        transition.setExpanded(true, at: 10)
        XCTAssertEqual(transition.blend(at: 10.175), 0.5, accuracy: 0.001)
        let before = transition.blend(at: 10.1)
        let opacity = transition.otherOpacity(at: 10.1)
        transition.setExpanded(false, at: 10.1)
        XCTAssertEqual(transition.blend(at: 10.1), before, accuracy: 0.001)
        XCTAssertEqual(transition.otherOpacity(at: 10.1), opacity, accuracy: 0.001)
        XCTAssertEqual(transition.blend(at: 10.45), 0, accuracy: 0.001)
        XCTAssertEqual(transition.otherOpacity(at: 10.30), 1, accuracy: 0.001)
    }
}
