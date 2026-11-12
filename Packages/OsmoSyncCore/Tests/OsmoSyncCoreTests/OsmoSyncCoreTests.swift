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

// MARK: DUML (Osmo Pocket)

final class DUMLTests: XCTestCase {
    /// Byte vectors from the Osmosis / OpenCine test suites.
    func testEncodesKnownFrames() {
        XCTAssertEqual(DUML.crc8([0x55, 0x11, 0x04][...]), 0x92)
        let playback = DUML.encode(.init(receiver: DUML.rxCamera, seq: 0xA000, flags: DUML.flagRequest,
                                         cmdSet: 0x02, cmdID: 0x0C, payload: [0x01, 0x01, 0x00, 0x01]))
        XCTAssertEqual(playback, [0x55, 0x11, 0x04, 0x92, 0x02, 0x01, 0x00, 0xA0,
                                  0x40, 0x02, 0x0C, 0x01, 0x01, 0x00, 0x01, 0xB6, 0x3B])
        let pin = DUML.encode(DUML.setPairingPin(identifier: "284ae5b8d76b3375a04a6417ad71bea3"))
        XCTAssertEqual(pin.count, 51)
        XCTAssertEqual(Array(pin.prefix(11)), [0x55, 0x33, 0x04, 0xC2, 0x02, 0x07, 0x92, 0x80, 0x40, 0x07, 0x45])
        XCTAssertEqual(Array(pin.suffix(2)), [0xA0, 0xB4])
    }

    func testParsesAndAssembles() {
        let rec = DUML.encode(DUML.record(start: true, seq: 0x8101))
        XCTAssertEqual(DUML.parse(rec)?.payload, [0x01])
        var bad = rec; bad[11] ^= 0xFF
        XCTAssertNil(DUML.parse(bad))

        let reply = DUML.encode(.init(sender: 0x01, receiver: 0x02, seq: 0x8101, flags: DUML.flagResponse,
                                      cmdSet: 0x02, cmdID: 0x02, payload: [0x00]))
        var asm = DUMLFrameAssembler()
        let stream = [0x00, 0x55, 0x01] + rec + reply  // junk, a stray SOF, then two frames
        XCTAssertEqual(asm.append(Array(stream[0..<9])), [])
        XCTAssertEqual(asm.append(Array(stream[9...])), [rec, reply])
        XCTAssertTrue(DUML.parse(reply)!.isResponse)
    }

    func testPairingReply() {
        XCTAssertEqual(DUML.pairingReply([0x00, 0x01]), .alreadyPaired)
        XCTAssertEqual(DUML.pairingReply([0x00, 0x02]), .needsApproval)
        XCTAssertEqual(DUML.pairingReply([0x00, 0x06]), .deferred)
    }
}

/// Byte examples from OpenCine's `DumlTransportTests` and `MulticamTests`.
final class DUMLDatalinkTests: XCTestCase {
    func testTransportHeader() {
        let h = DUMLDatalink.transportHeader(type: 0x05, payloadLength: 29, session: 0x3A7C, seq: 0xB890)
        XCTAssertEqual(h, [0x25, 0x80, 0x7C, 0x3A, 0x90, 0xB8, 0x05, 0xCE])
        XCTAssertEqual(h.reduce(0, ^), 0)
    }

    func testRoutingHeader() {
        XCTAssertEqual(DUMLDatalink.routingHeader(seq: 0xB890, counter: 0x06),
                       [0x88, 0xB8, 0x90, 0xB8, 0, 0, 0, 0, 0x06, 0x01, 0, 0])
    }

    func testHandshake() {
        let p = DUMLDatalink.handshake(session: 0x1234, seq: 0, baseSeq: 0xB887)
        XCTAssertEqual(p.count, 48)
        XCTAssertEqual(Array(p[0..<8]), [0x30, 0x80, 0x34, 0x12, 0x00, 0x00, 0x00, 0x96])
        XCTAssertEqual(Array(p[8..<14]), [0x87, 0xB8, 0x64, 0x00, 0x64, 0x00])
    }

    func testAckPayload() {
        let p = DUMLDatalink.ackPayload(video: 0x1234, ackedData: 0x5678, extra: 0x5678)
        XCTAssertEqual(p.count, 26)
        XCTAssertEqual(Array(p[0..<8]), [0x34, 0x12, 0x34, 0x12, 0, 0, 0, 0])
        XCTAssertEqual(Array(p[8..<16]), [0x78, 0x56, 0x78, 0x56, 0, 0, 0, 0])
        XCTAssertEqual(DUMLDatalink.ack(session: 1, video: 0, ackedData: 0, extra: 0).count, 34)
    }

    func testCommandRoundTripAndScan() {
        let rec = DUML.record(start: true, seq: 0xA000)
        let pkt = DUMLDatalink.command(rec, session: 0x3A7C, seq: 0xB890, counter: 1)
        XCTAssertEqual(pkt.count, 8 + 12 + 14)
        XCTAssertEqual(DUMLDatalink.packetType(pkt), 0x05)
        XCTAssertEqual(DUMLDatalink.frames(in: pkt), [rec])
        XCTAssertEqual(DUMLDatalink.frames(in: pkt + pkt), [rec, rec])
    }

    func testInitialWindow() {
        var tel = DUMLDatalink.transportHeader(type: 0x01, payloadLength: 26, session: 1, seq: 0)
        tel += [UInt8](repeating: 0, count: 26)
        tel[8] = 0x10; tel[9] = 0x20
        tel[18] = 0x38; tel[19] = 0xCD
        XCTAssertEqual(DUMLDatalink.commandSeq(fromInitialWindow: tel), 0x2018)
        XCTAssertEqual(DUMLDatalink.telemetryWindows(tel)?.ackedData, 0xCD38)
        XCTAssertNil(DUMLDatalink.commandSeq(fromInitialWindow: Array(tel[0..<8])))
        XCTAssertTrue(DUMLDatalink.isForward(0x0008, from: 0xFFF8))
        XCTAssertFalse(DUMLDatalink.isForward(0xFFF8, from: 0x0008))
    }

    func testStationCommands() {
        let s = DUML.stationMode(true, seq: 42)
        XCTAssertEqual([s.receiver, s.cmdSet, s.cmdID, s.flags], [7, 7, 0x48, 0x40])
        XCTAssertEqual(s.payload, [1])
        XCTAssertEqual(DUML.wifiRole(seq: 1).payload, [0])
        XCTAssertEqual(DUML.wifiRole(seq: 1).cmdID, 0x39)
        let v = DUML.videoMode(seq: 1)
        XCTAssertEqual([v.receiver, v.cmdSet, v.cmdID], [8, 2, 0xE1])
        let j = DUML.joinWiFi(ssid: "Café", password: "", seq: 1)!
        XCTAssertEqual(j.payload, [5] + Array("Café".utf8) + [0])
        XCTAssertNil(DUML.joinWiFi(ssid: String(repeating: "a", count: 33), password: "", seq: 1))
        XCTAssertEqual(DUML.appDeviceInfo(seq: 0).receiver, 0x48)
        XCTAssertEqual(DUML.appPresence(seq: 0).receiver, 0x28)
    }

    func testStationPolicy() {
        XCTAssertEqual(DUMLStation.role([0, 1]), .station)
        XCTAssertEqual(DUMLStation.role([0, 0]), .accessPoint)
        XCTAssertEqual(DUMLStation.joinResult([0, 0], attempt: 1), .joined)
        XCTAssertEqual(DUMLStation.joinResult([1, 0xFF], attempt: 1), .retry)
        XCTAssertEqual(DUMLStation.joinResult([1, 0xFF], attempt: 3), .rejected)
        XCTAssertEqual(DUMLStation.hosts(address: "192.168.1.20", mask: "255.255.255.0")?.count, 253)
        XCTAssertNil(DUMLStation.hosts(address: "10.0.0.2", mask: "255.0.0.0"))
    }
}
