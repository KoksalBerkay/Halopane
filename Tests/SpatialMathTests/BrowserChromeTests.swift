import CoreGraphics
import XCTest
import SpatialMath
import simd

final class BrowserChromeTests: XCTestCase {
    func testToolbarRayHitsTheRenderedAddressRegion() throws {
        let rect = BrowserChromeLayout.frame(.address)
        let world = WebPanelMath.sourceToWorld * SIMD4(Float(rect.midX), Float(rect.midY), 0, 1)
        let ray = try XCTUnwrap(PointerRay(direction: SIMD3(world.x, world.y, world.z)))
        XCTAssertNil(WebPanelMath.point(for: ray))
        let uv = try XCTUnwrap(WebPanelMath.point(for: ray, topInset: Float(BrowserChromeLayout.height)))
        XCTAssertEqual(BrowserChromeLayout.action(at: CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y))), .address)
        XCTAssertNil(BrowserChromeLayout.action(at: CGPoint(x: 500, y: 10)))
    }
}
