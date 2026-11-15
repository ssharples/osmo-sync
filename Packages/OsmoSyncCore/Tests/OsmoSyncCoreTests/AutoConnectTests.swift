import XCTest
@testable import OsmoSyncCore

final class AutoConnectTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testPocketMatchesByVendorAndName() {
        XCTAssertTrue(PocketUSB.isPocket(vendorID: 0x2CA3, productName: "OsmoPocket4P-A1B2C3D4E5F6G7"))
        XCTAssertFalse(PocketUSB.isPocket(vendorID: 0x2CA3, productName: "Wireless Mic Rx"))
        XCTAssertFalse(PocketUSB.isPocket(vendorID: 0x05E3, productName: "Osmo hub"))
        XCTAssertFalse(PocketUSB.isPocket(vendorID: 0x2CA3, productName: nil))
    }

    func testNudgeConnectsAtOnceEvenAfterDisconnect() {
        var a = AutoConnect()
        XCTAssertEqual(a.next(link: .off, wifiHealthy: false, wifiSetUp: true, nudged: true, userStopped: true, now: t0), .connect)
        XCTAssertEqual(a.next(link: .off, wifiHealthy: false, wifiSetUp: true, nudged: false, userStopped: true, now: t0), .none)
    }

    func testReadyButOffWiFiRejoinsOnNudgeOnly() {
        var a = AutoConnect()
        XCTAssertEqual(a.next(link: .ready, wifiHealthy: false, wifiSetUp: true, nudged: true, userStopped: false, now: t0), .rejoinWiFi)
        // The Wi-Fi watchdog covers the quiet case.
        XCTAssertEqual(a.next(link: .ready, wifiHealthy: false, wifiSetUp: true, nudged: false, userStopped: false, now: t0), .none)
        XCTAssertEqual(a.next(link: .ready, wifiHealthy: true, wifiSetUp: true, nudged: true, userStopped: false, now: t0), .none)
        XCTAssertEqual(a.next(link: .ready, wifiHealthy: false, wifiSetUp: false, nudged: true, userStopped: false, now: t0), .none)
    }

    func testStuckAttemptRestartsOnNudge() {
        var a = AutoConnect()
        let since = t0
        XCTAssertEqual(a.next(link: .connecting(since: since), wifiHealthy: false, wifiSetUp: true, nudged: true, userStopped: false, now: t0 + 5), .none)
        XCTAssertEqual(a.next(link: .connecting(since: since), wifiHealthy: false, wifiSetUp: true, nudged: true, userStopped: false, now: t0 + 30), .restart)
        XCTAssertEqual(a.next(link: .connecting(since: since), wifiHealthy: false, wifiSetUp: true, nudged: false, userStopped: false, now: t0 + 300), .none)
        XCTAssertEqual(a.next(link: .approving, wifiHealthy: false, wifiSetUp: true, nudged: true, userStopped: false, now: t0), .none)
    }

    func testFailuresBackOff() {
        var a = AutoConnect(firstGap: 20, maxGap: 300)
        func tick(_ s: Double) -> AutoConnect.Action {
            a.next(link: .failed, wifiHealthy: false, wifiSetUp: true, nudged: false, userStopped: false, now: t0 + s)
        }
        XCTAssertEqual(tick(0), .connect)     // then wait 20
        XCTAssertEqual(tick(10), .none)
        XCTAssertEqual(tick(21), .connect)    // then wait 40
        XCTAssertEqual(tick(50), .none)
        XCTAssertEqual(tick(62), .connect)
        // Getting connected clears the backoff.
        _ = a.next(link: .ready, wifiHealthy: true, wifiSetUp: true, nudged: false, userStopped: false, now: t0 + 70)
        XCTAssertEqual(tick(71), .connect)
    }
}
