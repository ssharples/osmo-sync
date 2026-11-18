import XCTest
@testable import OsmoSyncCore

final class CopyGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let g = CopyGate()

    func testWaitsFiveMinutesAfterRecording() {
        XCTAssertNotEqual(g.check(now: t0.addingTimeInterval(299), waitingSince: t0, recording: false,
                                  lastRecordingEnded: t0, webcamInUse: false, lastHot: nil), .go)
        XCTAssertEqual(g.check(now: t0.addingTimeInterval(300), waitingSince: t0, recording: false,
                               lastRecordingEnded: t0, webcamInUse: false, lastHot: nil), .go)
    }

    func testNeverCopiesWhileRecording() {
        XCTAssertEqual(g.check(now: t0.addingTimeInterval(9999), waitingSince: t0, recording: true,
                               lastRecordingEnded: nil, webcamInUse: false, lastHot: nil),
                       .wait("the camera is recording"))
    }

    func testWaitsForHeatFlagToClear() {
        XCTAssertNotEqual(g.check(now: t0.addingTimeInterval(100), waitingSince: t0, recording: false,
                                  lastRecordingEnded: nil, webcamInUse: false, lastHot: t0), .go)
    }

    func testWebcamWaitHasALimit() {
        XCTAssertEqual(g.check(now: t0.addingTimeInterval(600), waitingSince: t0, recording: false,
                               lastRecordingEnded: nil, webcamInUse: true, lastHot: nil),
                       .wait("an app is using the camera as a webcam"))
        XCTAssertEqual(g.check(now: t0.addingTimeInterval(3600), waitingSince: t0, recording: false,
                               lastRecordingEnded: nil, webcamInUse: true, lastHot: nil), .go)
    }
}
