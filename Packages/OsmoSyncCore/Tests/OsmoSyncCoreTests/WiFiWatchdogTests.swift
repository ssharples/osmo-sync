import XCTest
@testable import OsmoSyncCore

final class WiFiWatchdogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testWaitsForGraceThenRejoins() {
        var w = WiFiWatchdog(grace: 15, firstGap: 30)
        XCTAssertEqual(w.check(now: at(0), bleReady: true, linkHealthy: false, held: false), .wait)
        XCTAssertEqual(w.check(now: at(10), bleReady: true, linkHealthy: false, held: false), .wait)
        XCTAssertEqual(w.check(now: at(15), bleReady: true, linkHealthy: false, held: false), .rejoin)
    }

    func testBacksOffBetweenTries() {
        var w = WiFiWatchdog(grace: 15, firstGap: 30, maxGap: 100)
        _ = w.check(now: at(0), bleReady: true, linkHealthy: false, held: false)
        XCTAssertEqual(w.check(now: at(15), bleReady: true, linkHealthy: false, held: false), .rejoin)
        XCTAssertEqual(w.check(now: at(40), bleReady: true, linkHealthy: false, held: false), .wait)
        XCTAssertEqual(w.check(now: at(45), bleReady: true, linkHealthy: false, held: false), .rejoin)  // +30
        XCTAssertEqual(w.check(now: at(100), bleReady: true, linkHealthy: false, held: false), .wait)
        XCTAssertEqual(w.check(now: at(105), bleReady: true, linkHealthy: false, held: false), .rejoin) // +60
        XCTAssertEqual(w.check(now: at(205), bleReady: true, linkHealthy: false, held: false), .rejoin) // capped at 100
    }

    func testHealthyLinkOrNoBluetoothResets() {
        var w = WiFiWatchdog(grace: 15, firstGap: 30)
        _ = w.check(now: at(0), bleReady: true, linkHealthy: false, held: false)
        XCTAssertEqual(w.check(now: at(10), bleReady: true, linkHealthy: true, held: false), .wait)
        XCTAssertNil(w.downSince)
        XCTAssertEqual(w.check(now: at(20), bleReady: true, linkHealthy: false, held: false), .wait)
        XCTAssertEqual(w.check(now: at(30), bleReady: false, linkHealthy: false, held: false), .wait)
        XCTAssertNil(w.downSince)
    }

    func testHeldNeverRejoins() {
        var w = WiFiWatchdog(grace: 15, firstGap: 30)
        for s in stride(from: 0.0, through: 120, by: 5) {
            XCTAssertEqual(w.check(now: at(s), bleReady: true, linkHealthy: false, held: true), .wait)
        }
        // Once released, the grace period starts again.
        XCTAssertEqual(w.check(now: at(125), bleReady: true, linkHealthy: false, held: false), .wait)
        XCTAssertEqual(w.check(now: at(140), bleReady: true, linkHealthy: false, held: false), .rejoin)
    }
}
