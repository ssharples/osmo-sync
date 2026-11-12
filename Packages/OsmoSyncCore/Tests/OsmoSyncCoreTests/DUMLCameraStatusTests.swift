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
