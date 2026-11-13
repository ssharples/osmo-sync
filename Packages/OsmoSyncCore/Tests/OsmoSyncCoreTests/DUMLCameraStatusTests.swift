import XCTest
@testable import OsmoSyncCore

final class DUMLCameraStatusTests: XCTestCase {
    func frame(_ p: [UInt8]) -> DUML.Frame {
        DUML.Frame(sender: 0x01, receiver: 0x02, seq: 0, flags: 0x00, cmdSet: 0x02, cmdID: 0x80, payload: p)
    }

    func testIdleAndRecording() {
        var p = [UInt8](repeating: 0, count: 31)
        p[0] = 0x01
        XCTAssertEqual(DUMLCameraStatus(frame(p))?.isRecording, false)
        p[0] = 0x81; p[29] = 12
        let s = DUMLCameraStatus(frame(p))
        XCTAssertEqual(s?.isRecording, true)
        XCTAssertEqual(s?.elapsed, 12)
        p[3] = 0x40
        XCTAssertEqual(DUMLCameraStatus(frame(p))?.inPlayback, true)
    }

    func testRejectsOtherFrames() {
        XCTAssertNil(DUMLCameraStatus(frame([0x81])))
        var f = frame([UInt8](repeating: 0, count: 20)); f.cmdID = 0x81
        XCTAssertNil(DUMLCameraStatus(f))
    }
}

final class GimbalZoomTests: XCTestCase {
    func testStickCentresInsideDeadzone() {
        let f = DUML.gimbalStick(tilt: 0.05, pan: -0.03, seq: 1)
        XCTAssertEqual(f.cmdSet, 0x04); XCTAssertEqual(f.cmdID, 0x01); XCTAssertEqual(f.receiver, 0x04)
        XCTAssertEqual(f.flags, 0x00)
        XCTAssertEqual(f.payload, [0x00, 0x04, 0, 0, 0x00, 0x04, 0x00, 0x80, 0x22, 0x00])
    }

    func testStickFullThrowStaysInRange() {
        XCTAssertEqual(GimbalStick.axis(1), 1574)
        XCTAssertEqual(GimbalStick.axis(-1), 474)
        XCTAssertEqual(GimbalStick.axis(5), 1574)
        XCTAssertEqual(GimbalStick.axis(.nan), 1024)
        let f = DUML.gimbalStick(tilt: 1, pan: -1, seq: 1)
        XCTAssertEqual(Array(f.payload[0...1]), [0x26, 0x06])  // 1574 tilt up
        XCTAssertEqual(Array(f.payload[4...5]), [0xDA, 0x01])  // 474 pan left
    }

    func testRecentreFrame() {
        let f = DUML.gimbalRecentre(seq: 9)
        XCTAssertEqual([f.cmdSet, f.cmdID], [0x04, 0x4C])
        XCTAssertEqual(f.payload, [0xFE, 0x08])
    }

    func testZoomLensStops() {
        XCTAssertEqual(Zoom.lensPosition(for: 1), 217)
        XCTAssertEqual(Zoom.lensPosition(for: 2), 434)
        XCTAssertEqual(Zoom.lensPosition(for: 3), 651)
        XCTAssertEqual(Zoom.lensPosition(for: 12), 2604)
        XCTAssertEqual(Zoom.lensPosition(for: 40), 2604)
        XCTAssertEqual(Zoom.lensPosition(for: 0.5), 217)
        let f = DUML.zoom(factor: 3, seq: 1)
        XCTAssertEqual([f.cmdSet, f.cmdID], [0x02, 0xB8])
        XCTAssertEqual(f.payload, [0x0A, 0x4E, 0x8B, 0x02])
    }

    func testTrackSubjectMatchesMimoLayout() {
        let f = DUML.trackSubject(id: 0x2726, centreX: 0.5, centreY: 0.25, width: 1, height: 2, seq: 1)
        XCTAssertEqual([f.cmdSet, f.cmdID], [0x02, 0xA6])
        XCTAssertEqual(f.payload.count, 21)
        XCTAssertEqual(Array(f.payload.prefix(5)), [0x01, 0x00, 0x00, 0x26, 0x27])
        XCTAssertEqual(Array(f.payload[5..<9]), [0x00, 0x00, 0x00, 0x3F])    // 0.5
        XCTAssertEqual(Array(f.payload[9..<13]), [0x00, 0x00, 0x80, 0x3E])   // 0.25
        XCTAssertEqual(Array(f.payload[13..<17]), [0x00, 0x00, 0x80, 0x3F])  // 1
        XCTAssertEqual(Array(f.payload[17..<21]), [0x00, 0x00, 0x00, 0x40])  // 2
        XCTAssertEqual(DUML.stopTracking(seq: 1).payload, [UInt8](repeating: 0, count: 21))
    }

    func testTrackingReply() {
        XCTAssertTrue(DUML.isTrackingLocked([0x00, 0x01, 0x00, 0x00]))
        XCTAssertFalse(DUML.isTrackingLocked([0x00, 0x00, 0x00, 0x00]))
        XCTAssertFalse(DUML.isTrackingLocked([0x00]))
    }

    func testFocusBurst() {
        let b = DUML.focus(x: 0.5, y: 0.5, seq: 1)
        XCTAssertEqual(b.map(\.cmdID), [0x22, 0x30, 0x68, 0x32])
        XCTAssertEqual(b[1].payload.count, 21)
        XCTAssertEqual(Array(b[1].payload[0..<4]), [0x00, 0x00, 0x00, 0x3F])
        XCTAssertEqual(Array(b[3].payload[0..<4]), [0x00, 0x02, 0x01, 0x00])
        XCTAssertEqual(b[3].payload.count, 20)
    }
}
