import CoreGraphics
import XCTest
import SpatialMath

final class CinemaMappingTests: XCTestCase {
    func testCropPreservesAspectAndMapsTapsBackToVideo() throws {
        let crop = CGRect(x: 120, y: 80, width: 480, height: 270)
        let mapping = try XCTUnwrap(CinemaMapping(crop: crop))
        XCTAssertEqual(mapping.destination.width, 1000, accuracy: 0.001)
        XCTAssertEqual(mapping.destination.height, 562.5, accuracy: 0.001)
        let hit = try XCTUnwrap(mapping.sourcePoint(at: CGPoint(x: 750, y: mapping.destination.midY)))
        XCTAssertEqual(hit.x, crop.minX + crop.width * 0.75, accuracy: 0.001)
        XCTAssertEqual(hit.y, crop.midY, accuracy: 0.001)
        XCTAssertNil(mapping.sourcePoint(at: .zero))
        XCTAssertNil(CinemaMapping(crop: crop.offsetBy(dx: -200, dy: 0)))
    }
}

final class StereoCinemaLayoutTests: XCTestCase {
    let eye = CGSize(width: 1920, height: 1200)
    let visible = CGRect(x: 0, y: 300, width: 1920, height: 900)

    func testFullAndHalfPackingHaveTheSamePerEyeAspect() throws {
        let full = try XCTUnwrap(
            StereoCinemaLayout(
                crop: CGRect(x: 10, y: 20, width: 960, height: 270),
                eyeSize: eye, visible: visible, packing: .sideBySide))
        let half = try XCTUnwrap(
            StereoCinemaLayout(
                crop: CGRect(x: 10, y: 20, width: 480, height: 270),
                eyeSize: eye, visible: visible, packing: .halfSideBySide))
        XCTAssertEqual(full.packedFrame, half.packedFrame)
        XCTAssertEqual(full.packedFrame.midX, eye.width)
        XCTAssertEqual(full.packedFrame.midY, visible.midY)
        XCTAssertEqual(full.packedFrame.height, 1080)
        XCTAssertEqual(full.eyeClip, visible)
        XCTAssertEqual(full.scaleX, full.scaleY)
        XCTAssertEqual(half.scaleX, 2 * half.scaleY)
    }

    func testSwapPlacesOppositeHalvesInEachPhysicalEye() throws {
        let swapped = try XCTUnwrap(
            StereoCinemaLayout(
                crop: CGRect(x: 0, y: 0, width: 960, height: 270),
                eyeSize: eye, visible: visible, packing: .sideBySide, swapped: true))
        let left = CGRect(x: 0, y: swapped.packedFrame.minY, width: eye.width, height: swapped.packedFrame.height)
        let right = left.offsetBy(dx: eye.width, dy: 0)
        XCTAssertEqual(swapped.packedFrame.intersection(left), left)
        XCTAssertTrue(swapped.packedFrame.intersection(right).isEmpty)
        XCTAssertEqual(swapped.packedFrame.offsetBy(dx: swapped.instanceOffset, dy: 0).intersection(right), right)
        XCTAssertEqual(swapped.packedFrame.midX, 0)
        XCTAssertEqual(swapped.packedFrame.minX + swapped.instanceOffset, eye.width)
    }

    func testRejectsInvalidViewportOrCrop() {
        XCTAssertNil(StereoCinemaLayout(crop: .zero, eyeSize: eye, visible: visible, packing: .sideBySide))
        XCTAssertNil(StereoCinemaLayout(crop: visible, eyeSize: eye, visible: .zero, packing: .sideBySide))
    }
}
