import XCTest
import SpatialMath

final class SerialTapQueueTests: XCTestCase {
    func testBurstDeliversInOrderWithoutOverlap() {
        var queue = SerialTapQueue<Int>()
        XCTAssertTrue(queue.enqueue(0))
        XCTAssertEqual(queue.startNext(), 0)
        for tap in 1...9 {
            XCTAssertTrue(queue.enqueue(tap))
            XCTAssertNil(queue.startNext())
        }
        for tap in 1...9 {
            queue.didFinish()
            XCTAssertEqual(queue.startNext(), tap)
        }
        queue.didFinish()
        XCTAssertNil(queue.startNext())
    }

    func testNavigationDiscardsOldTapsWithoutOverlappingActiveTap() {
        var queue = SerialTapQueue<Int>(capacity: 1)
        XCTAssertTrue(queue.enqueue(0))
        XCTAssertEqual(queue.startNext(), 0)
        XCTAssertTrue(queue.enqueue(1))
        XCTAssertFalse(queue.enqueue(2))
        queue.discardPending()
        XCTAssertTrue(queue.enqueue(3))
        XCTAssertNil(queue.startNext())
        queue.didFinish()
        XCTAssertEqual(queue.startNext(), 3)
    }
    func testPanelSwitchOnlyPurgesOldPanelPendingWork() {
        struct Input: Equatable {
            let panel: Int
            let sequence: Int
        }
        var queue = SerialTapQueue<Input>()
        let oldInFlight = Input(panel: 1, sequence: 1)
        let nextPanelTap = Input(panel: 2, sequence: 3)
        queue.enqueue(oldInFlight)
        XCTAssertEqual(queue.startNext(), oldInFlight)
        queue.enqueue(Input(panel: 1, sequence: 2))
        queue.enqueue(nextPanelTap)
        queue.removePending { $0.panel == 1 }
        XCTAssertNil(queue.startNext())
        queue.didFinish()
        XCTAssertEqual(queue.startNext(), nextPanelTap)
        queue.didFinish()
        XCTAssertTrue(queue.isIdle)
    }
}
