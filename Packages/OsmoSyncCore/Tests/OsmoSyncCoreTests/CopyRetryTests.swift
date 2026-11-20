import XCTest
@testable import OsmoSyncCore

final class CopyRetryTests: XCTestCase {
    func testDelaysDoubleFromTwoSecondsAndStopAtSixty() {
        let r = CopyRetry()
        XCTAssertEqual((1...8).map { r.delay(attempt: $0) }, [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(r.delay(attempt: 0), 2)
        XCTAssertEqual(r.delay(attempt: 500), 60)
    }

    func testGivesUpAfterEightFailuresInARow() {
        let r = CopyRetry()
        XCTAssertTrue(r.shouldRetry(attempt: 8))
        XCTAssertFalse(r.shouldRetry(attempt: 9))
    }

    func testTotalWaitIsAboutFourMinutes() {
        let r = CopyRetry()
        let total = (1...r.maxAttempts).map { r.delay(attempt: $0) }.reduce(0, +)
        XCTAssertEqual(total, 242)
    }

    func testMacOffHotspotRejoinsThenRestartsHotspot() {
        let r = CopyRetry()
        XCTAssertEqual(r.step(attempt: 1, macOnHotspot: false, rejoinFailedBefore: false), .rejoinMac)
        XCTAssertEqual(r.step(attempt: 2, macOnHotspot: false, rejoinFailedBefore: true), .restartHotspot)
    }

    func testOnHotspotButFailingRetriesThenRestarts() {
        let r = CopyRetry()
        XCTAssertEqual(r.step(attempt: 1, macOnHotspot: true, rejoinFailedBefore: false), .retry)
        XCTAssertEqual(r.step(attempt: 2, macOnHotspot: true, rejoinFailedBefore: false), .retry)
        XCTAssertEqual(r.step(attempt: 3, macOnHotspot: true, rejoinFailedBefore: false), .restartHotspot)
    }

    func testRangesPastTwoAndFourGigabytes() {
        let chunk: Int64 = 32 << 20
        let size: Int64 = 5_000_000_000
        XCTAssertEqual(CopyRange.header(from: 0, size: size, chunk: chunk), "bytes=0-33554431")
        let past2G: Int64 = 2_181_038_080
        XCTAssertEqual(CopyRange.header(from: past2G, size: size, chunk: chunk), "bytes=2181038080-2214592511")
        let past4G: Int64 = 4_294_967_296
        XCTAssertEqual(CopyRange.header(from: past4G, size: size, chunk: chunk), "bytes=4294967296-4328521727")
        XCTAssertEqual(CopyRange.header(from: size - 10, size: size, chunk: chunk), "bytes=4999999990-4999999999")
        XCTAssertNil(CopyRange.header(from: size, size: size, chunk: chunk))
    }

    func testResumePoint() {
        XCTAssertEqual(CopyRange.resumePoint(partSize: nil, size: 100), 0)
        XCTAssertEqual(CopyRange.resumePoint(partSize: 2_214_592_512, size: 2_415_919_104), 2_214_592_512)
        XCTAssertEqual(CopyRange.resumePoint(partSize: 200, size: 100), 0)
        XCTAssertEqual(CopyRange.resumePoint(partSize: 100, size: 100), 100)
    }
}

final class HotspotRoleTests: XCTestCase {
    func testPocket4PHotspotReadsAsAccessPoint() {
        XCTAssertEqual(DUMLStation.role([0, 8]), .accessPoint)
        XCTAssertEqual(DUMLStation.role([0, 0]), .accessPoint)
        XCTAssertEqual(DUMLStation.role([0, 1]), .station)
    }

    func testRadioOffIsNotAHotspot() {
        XCTAssertEqual(DUMLStation.role([0, 0xFF]), .unknown)
        XCTAssertEqual(DUMLStation.role([]), .unknown)
    }
}

final class HotspotReachTests: XCTestCase {
    func testAsksThenRestartsWithBackoffThenGivesUp() {
        let r = HotspotReach()
        XCTAssertEqual(r.step(attempt: 1), .switchToHotspot)
        XCTAssertEqual(r.step(attempt: 2), .restartHotspot(wait: 2))
        XCTAssertEqual(r.step(attempt: 3), .restartHotspot(wait: 4))
        XCTAssertEqual(r.step(attempt: 4), .giveUp)
    }

    func testSkipsTheMacJoinUntilTheHotspotIsConfirmed() {
        let r = HotspotReach()
        XCTAssertFalse(r.shouldJoin(confirmed: false, attempt: 1))
        XCTAssertTrue(r.shouldJoin(confirmed: true, attempt: 1))
        XCTAssertTrue(r.shouldJoin(confirmed: false, attempt: 3))
    }
}
