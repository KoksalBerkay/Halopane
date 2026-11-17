import XCTest
import SpatialMath
import simd

final class PanelOffsetTests: XCTestCase {
    func testCenterAndRightPanelStaySeparatedAcrossWorkspaceRecenters() throws {
        let center = PanelOffset()
        let side = PanelOffset.side
        let forward = SIMD3<Float>(0, 0, -1)
        XCTAssertGreaterThan(side.rotation.act(forward).x, 0)
        for workspace in [SceneMath.identity, simd_quatf(angle: 0.5, axis: SIMD3<Float>(1, 0, 0))] {
            let a = center.anchor(in: workspace).act(forward)
            let b = side.anchor(in: workspace).act(forward)
            XCTAssertEqual(simd_dot(a, b), cos(36 * .pi / 180), accuracy: 0.001)
            let ray = try XCTUnwrap(PointerRay(direction: b))
            XCTAssertNil(center.point(for: ray, workspace: workspace))
            let hit = try XCTUnwrap(side.point(for: ray, workspace: workspace))
            XCTAssertEqual(hit.x, 500, accuracy: 0.001)
            XCTAssertEqual(hit.y, 312.5, accuracy: 0.001)
            let camera = side.camera(workspace.inverse * side.anchor(in: workspace))
            XCTAssertEqual(SceneMath.axisAngle(camera).degrees, 0, accuracy: 0.001)
        }
    }
    func testPointerCanSelectEitherPanelAndPrefersVisibleFocusInAnOverlap() throws {
        let workspace = simd_quatf(angle: 0.19, axis: SIMD3<Float>(1, 0, 0))
        let panels: [PanelPointerHit.Candidate] = [
            .init(number: 1, offset: PanelOffset()), .init(number: 2, offset: .side)
        ]
        for candidate in panels {
            let ray = try XCTUnwrap(
                PointerRay(direction: candidate.offset.anchor(in: workspace).act(SIMD3<Float>(0, 0, -1))))
            let hit = try XCTUnwrap(
                PanelPointerHit.resolve(
                    ray: ray, workspace: workspace, selected: 3 - candidate.number,
                    panels: panels, topInset: 56))
            XCTAssertEqual(hit.panel, candidate.number)
            XCTAssertEqual(hit.point.x, 500, accuracy: 0.001)
            XCTAssertEqual(hit.point.y, 312.5, accuracy: 0.001)
        }
        let ray = try XCTUnwrap(PointerRay(direction: workspace.act(SIMD3<Float>(0, 0, -1))))
        XCTAssertEqual(
            PanelPointerHit.resolve(
                ray: ray, workspace: workspace, selected: 2,
                panels: [.init(number: 1, offset: PanelOffset()), .init(number: 2, offset: PanelOffset())], topInset: 56
            )?.panel, 2)
    }
    func testFourSlotsKeepDistinctIdentityWhenSelectionAndVisualOrderChange() throws {
        let workspace = WebPanelMath.levelAnchor(lookingWith: simd_quatf(angle: 0.31, axis: SIMD3<Float>(0, 1, 0)))
        let panels: [PanelPointerHit.Candidate] = [
            .init(number: 41, offset: .slot(0)), .init(number: 82, offset: .slot(1)),
            .init(number: 19, offset: .slot(2)), .init(number: 72, offset: .slot(3))
        ]
        for candidate in panels.reversed() {
            let ray = try XCTUnwrap(
                PointerRay(direction: candidate.offset.anchor(in: workspace).act(SIMD3<Float>(0, 0, -1))))
            let hit = try XCTUnwrap(
                PanelPointerHit.resolve(ray: ray, workspace: workspace, selected: 41, panels: panels, topInset: 56))
            XCTAssertEqual(hit.panel, candidate.number)
            XCTAssertEqual(hit.point.x, 500, accuracy: 0.1)
            XCTAssertEqual(hit.point.y, 312.5, accuracy: 0.1)
        }
    }
}
