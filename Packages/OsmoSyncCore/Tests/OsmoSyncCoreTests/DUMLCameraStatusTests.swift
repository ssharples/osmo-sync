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
}
