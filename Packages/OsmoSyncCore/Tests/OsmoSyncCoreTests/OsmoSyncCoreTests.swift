import XCTest
@testable import OsmoSyncCore

final class RSDKTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// Golden frames from DJI's own builder: test/connect_cmd_frame_builder/connect_cmd_frame.txt.
    func testConnectionRequestMatchesDJIGoldenFrames() {
        let golden: [(UInt16, String)] = [
            (0x1FFE, "AA330002000000000100982F00197856341206383456789ABC00000000000000000000000000000000FE1F00000000796C667C"),
            (0x1A19, "AA330002000000000100982F00197856341206383456789ABC00000000000000000000000000000000191A0000000033C8C7BF"),
            (0x0210, "AA330002000000000100982F00197856341206383456789ABC00000000000000000000000000000000100C00000000D9FB6877"),
        ]
        let mac: [UInt8] = [0x38, 0x34, 0x56, 0x78, 0x9A, 0xBC]
        for (code, expected) in golden.prefix(2) {
            let payload = RSDK.connectionRequest(deviceID: 0x1234_5678, mac: mac, verifyMode: 0, verifyData: code)
            let f = RSDK.frame(cmdSet: 0x00, cmdID: 0x19, cmdType: RSDK.cmdWaitResult, payload: payload, seq: 1)
            XCTAssertEqual(f, hex(expected))
        }
        // Third line: verify_data 0x0C10.
        let p = RSDK.connectionRequest(deviceID: 0x1234_5678, mac: mac, verifyMode: 0, verifyData: 0x0C10)
        XCTAssertEqual(RSDK.frame(cmdSet: 0, cmdID: 0x19, cmdType: 2, payload: p, seq: 1), hex(golden[2].1))
    }

    func testRoundTripAndCRCRejection() {
        let f = RSDK.frame(cmdSet: RSDK.setCamera, cmdID: RSDK.idRecordControl, cmdType: RSDK.cmdWaitResult,
                           payload: RSDK.recordControl(deviceID: 0xFF33, start: true), seq: 7)
        let parsed = RSDK.parse(f)
        XCTAssertEqual(parsed?.cmdSet, 0x1D)
        XCTAssertEqual(parsed?.cmdID, 0x03)
        XCTAssertEqual(parsed?.seq, 7)
        XCTAssertEqual(parsed?.payload, [0x33, 0xFF, 0, 0, 0, 0, 0, 0, 0])
        var bad = f
        bad[15] ^= 0xFF
        XCTAssertNil(RSDK.parse(bad))
    }

    func testAssemblerJoinsSplitFramesAndSkipsJunk() {
        let a = RSDK.frame(cmdSet: 0x1D, cmdID: 0x02, cmdType: 0, payload: Array(repeating: 1, count: 38), seq: 1)
        let b = RSDK.frame(cmdSet: 0x00, cmdID: 0x19, cmdType: 0, payload: Array(repeating: 2, count: 33), seq: 2)
        var asm = RSDKFrameAssembler()
        XCTAssertEqual(asm.append([0x00, 0xAA, 0x01] + Array(a[0..<10])), [])
        XCTAssertEqual(asm.append(Array(a[10...]) + Array(b[0..<5])), [a])
        XCTAssertEqual(asm.append(Array(b[5...])), [b])
    }

    func testConnectionVerdictAndStatus() {
        var p = RSDK.connectionRequest(deviceID: 0xFF44, mac: [1, 2, 3, 4, 5, 6], verifyMode: 2, verifyData: 0)
        XCTAssertEqual(RSDK.connectionVerdict(p), .approved)
        p[27] = 1
        XCTAssertEqual(RSDK.connectionVerdict(p), .rejected)

        var s = [UInt8](repeating: 0, count: 38)
        s[0] = 0x01; s[1] = 0x03; s[5] = 0x2C; s[6] = 0x01; s[37] = 87
        let status = RSDK.cameraStatus(s)
        XCTAssertEqual(status?.isRecording, true)
        XCTAssertEqual(status?.recordSeconds, 300)
        XCTAssertEqual(status?.battery, 87)
        XCTAssertEqual(status?.modeName, "Video")
    }
}

final class ScreenStudioLogTests: XCTestCase {
    func testEventsFromRealLogLines() {
        XCTAssertEqual(ScreenStudioLog.event(in: "2026-10-23T17:45:52.110+0100 debug    [Conductor] Starting recording."), .starting)
        XCTAssertEqual(ScreenStudioLog.event(in: "2026-10-01T18:02:13.145+0100 warning  [Conductor] Pausing the recording to be able to stop."), .stopping)
        XCTAssertEqual(ScreenStudioLog.event(in: "2026-10-01T18:02:14.209+0100 notice   [Conductor] Recording stopped. errorCount=0 metadataCount=5 recorders=5"), .stopped)
        XCTAssertNil(ScreenStudioLog.event(in: "2026-10-01T17:59:04.395+0100 notice   [Conductor] Recording resumed. recordFrom=1"))
        XCTAssertNil(ScreenStudioLog.event(in: "2026-10-01T17:59:04.395+0100 notice   [Other] Starting recording."))
    }

    func testTimestampParsing() {
        let d = ScreenStudioLog.timestamp(of: "2026-10-23T17:45:52.110+0100 debug    [Conductor] Starting recording.")
        XCTAssertEqual(d?.timeIntervalSince1970 ?? 0, 1_792_773_952.110, accuracy: 0.001)
    }

    func testTailerFollowsNewProjectAndIgnoresOldOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("Old.screenstudio/recording")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "x [Conductor] Starting recording.\n".write(to: old.appendingPathComponent("polyrecorder.log"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: root.appendingPathComponent("Old.screenstudio").path)

        let tailer = ScreenStudioLogTailer(projectsFolder: root)
        XCTAssertEqual(tailer.poll(), [])

        let new = root.appendingPathComponent("New.screenstudio/recording")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let log = new.appendingPathComponent("polyrecorder.log")
        try "2026-10-23T17:45:52.110+0100 debug    [Conductor] Starting recording.\n2026-10-23T17:45:53".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(tailer.poll().map(\.event), [.starting])

        let h = try FileHandle(forWritingTo: log)
        h.seekToEndOfFile()
        h.write(".000+0100 notice [Conductor] Recording stopped. errorCount=0\n".data(using: .utf8)!)
        try h.close()
        XCTAssertEqual(tailer.poll().map(\.event), [.stopped])
        XCTAssertEqual(tailer.poll(), [])
    }
}

final class CameraMediaTests: XCTestCase {
    func testClipsInsideTakeWindow() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let files: [(url: URL, modified: Date, size: Int)] = [
            (URL(fileURLWithPath: "/a.MP4"), t0.addingTimeInterval(-600), 1),
            (URL(fileURLWithPath: "/b.MP4"), t0.addingTimeInterval(200), 1),
            (URL(fileURLWithPath: "/c.MP4"), t0.addingTimeInterval(305), 1),
            (URL(fileURLWithPath: "/d.MP4"), t0.addingTimeInterval(2000), 1),
        ]
        let picked = CameraMedia.clips(files, takeStart: t0, takeEnd: t0.addingTimeInterval(300))
        XCTAssertEqual(picked.map(\.lastPathComponent), ["b.MP4", "c.MP4"])
    }
}
