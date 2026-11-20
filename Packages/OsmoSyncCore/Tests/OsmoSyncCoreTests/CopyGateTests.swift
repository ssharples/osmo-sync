import XCTest
@testable import OsmoSyncCore

final class CopyGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let g = CopyGate()

    func testCopiesRightAwayWhenNotRecordingOrHot() {
        XCTAssertEqual(g.check(now: t0, recording: false, lastHot: nil), .go)
    }

    func testNeverCopiesWhileRecording() {
        XCTAssertEqual(g.check(now: t0, recording: true, lastHot: nil), .wait("the camera is recording"))
    }

    func testWaitsFiveMinutesAfterHeatFlag() {
        XCTAssertEqual(g.check(now: t0.addingTimeInterval(299), recording: false, lastHot: t0),
                       .wait("the camera reported it's hot"))
        XCTAssertEqual(g.check(now: t0.addingTimeInterval(300), recording: false, lastHot: t0), .go)
    }

    func testCoolsAtIsFiveMinutesAfterHeat() {
        XCTAssertNil(g.coolsAt(lastHot: nil))
        XCTAssertEqual(g.coolsAt(lastHot: t0), t0.addingTimeInterval(300))
    }
}
