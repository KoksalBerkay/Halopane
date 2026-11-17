import XCTest
import SpatialMath

final class PanelInputRouteTests: XCTestCase {
    func testSwitchDropsOldDragAndRoutesNewInputInBothDirections() {
        var route = PanelInputRoute(selected: 1)
        XCTAssertEqual(route.beginDrag(), 1)
        XCTAssertTrue(route.select(2))
        XCTAssertNil(route.dragPanel)
        XCTAssertNil(route.finishDrag())
        XCTAssertEqual(route.selected, 2)
        XCTAssertEqual(route.beginDrag(), 2)
        XCTAssertEqual(route.finishDrag(), 2)
        XCTAssertTrue(route.select(1))
        XCTAssertEqual(route.beginDrag(), 1)
    }
}
