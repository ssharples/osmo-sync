import XCTest
@testable import OsmoSyncCore

final class CameraRestTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRestsAfterTwoQuietMinutes() {
        let r = CameraRest()
        XCTAssertFalse(r.shouldRest(now: t0.addingTimeInterval(119), lastActivity: t0, busy: false, linkHealthy: true))
        XCTAssertTrue(r.shouldRest(now: t0.addingTimeInterval(120), lastActivity: t0, busy: false, linkHealthy: true))
    }

    func testNeverRestsWhileBusy() {
        let r = CameraRest()
        XCTAssertFalse(r.shouldRest(now: t0.addingTimeInterval(3600), lastActivity: t0, busy: true, linkHealthy: true))
    }

    func testLeavesABrokenLinkToTheWatchdog() {
        let r = CameraRest()
        XCTAssertFalse(r.shouldRest(now: t0.addingTimeInterval(3600), lastActivity: t0, busy: false, linkHealthy: false))
    }

    func testChecksOncePerMinuteAndWakesAfterTwoMisses() {
        let r = CameraRest()
        XCTAssertFalse(r.checkDue(now: t0.addingTimeInterval(59), lastCheck: t0))
        XCTAssertTrue(r.checkDue(now: t0.addingTimeInterval(60), lastCheck: t0))
        XCTAssertFalse(r.shouldWake(misses: 1))
        XCTAssertTrue(r.shouldWake(misses: 2))
    }
}
