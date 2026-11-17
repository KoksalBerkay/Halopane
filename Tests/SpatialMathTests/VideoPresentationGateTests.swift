import XCTest
@testable import SpatialMath

final class VideoPresentationGateTests: XCTestCase {
    func testDismissingRejectsBothDelayedCloseAndRepeatedPageFullScreen() {
        var gate = VideoPresentationGate()
        let captured = gate.revision
        XCTAssertTrue(gate.accepts(at: 1, revision: captured))
        gate.dismiss(at: 1.1)
        XCTAssertFalse(gate.accepts(at: 1.2))
        XCTAssertFalse(gate.accepts(at: 2.5, revision: captured))
        XCTAssertTrue(gate.accepts(at: 2.5))
    }

    func testNavigationDiscardsAnOldFullscreenCompletion() {
        var gate = VideoPresentationGate()
        let captured = gate.revision
        gate.dismiss(at: 3)
        gate.reset()
        XCTAssertFalse(gate.accepts(at: 3.1, revision: captured))
        XCTAssertTrue(gate.accepts(at: 3.1))
    }
}
