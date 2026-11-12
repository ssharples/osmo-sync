import Foundation

/// DJI R-SDK frames, the protocol DJI publishes for Bluetooth remotes
/// (github.com/dji-sdk/Osmo-GPS-Controller-Demo, docs/protocol.md).
///
/// Frame layout, all little-endian:
/// ```
/// 0      SOF       0xAA
/// 1-2    ver/len   (version << 10) | total length
/// 3      cmd type  bit 5 set = response frame
/// 4      enc       0
/// 5-7    reserved  0
/// 8-9    seq
/// 10-11  CRC16 of bytes 0...9
/// 12     cmd set
/// 13     cmd id
/// 14...  payload
/// last 4 CRC32 of everything before it
/// ```
/// It travels over GATT service FFF0: we write to FFF5 and the camera notifies on FFF4.
public enum RSDK {
    // MARK: Command types (enums_logic.h)
    public static let cmdNoResponse: UInt8 = 0x00
    public static let cmdResponseOrNot: UInt8 = 0x01
    public static let cmdWaitResult: UInt8 = 0x02
    public static let ackNoResponse: UInt8 = 0x20

    // MARK: Command set / id pairs
    public static let setGeneral: UInt8 = 0x00
    public static let idConnection: UInt8 = 0x19
    public static let setCamera: UInt8 = 0x1D
    public static let idStatusPush: UInt8 = 0x02
    public static let idRecordControl: UInt8 = 0x03
    public static let idStatusSubscribe: UInt8 = 0x05
    public static let idStatusPushNew: UInt8 = 0x06

    // MARK: CRCs (custom_crc16.c / custom_crc32.c: init 0x3AA3, reflected, no final xor)

    private static let crc16Table: [UInt16] = (0..<256).map { i in
        var c = UInt16(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        return c
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var c: UInt16 = 0x3AA3
        for b in bytes { c = crc16Table[Int((c ^ UInt16(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0x3AA3
        for b in bytes { c = crc32Table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    // MARK: Framing

    /// Wraps a payload in a full frame.
    public static func frame(cmdSet: UInt8, cmdID: UInt8, cmdType: UInt8, payload: [UInt8], seq: UInt16) -> [UInt8] {
        let total = 14 + payload.count + 4
        var f: [UInt8] = [0xAA]
        f.appendLE(UInt16(total & 0x3FF))
        f += [cmdType, 0, 0, 0, 0]
        f.appendLE(seq)
        f.appendLE(crc16(f))
        f += [cmdSet, cmdID]
        f += payload
        f.appendLE(crc32(f))
        return f
    }

    public struct Frame: Equatable {
        public let cmdSet: UInt8
        public let cmdID: UInt8
        public let cmdType: UInt8
        public let seq: UInt16
        public let payload: [UInt8]
        public var isResponse: Bool { cmdType & 0x20 != 0 }
    }

    /// Parses one complete frame. Returns nil when it is malformed or a CRC fails.
    public static func parse(_ f: [UInt8]) -> Frame? {
        guard f.count >= 18, f[0] == 0xAA else { return nil }
        let len = Int(UInt16(f[1]) | UInt16(f[2]) << 8) & 0x3FF
        guard len == f.count else { return nil }
        guard crc16(f[0..<10]) == UInt16(f[10]) | UInt16(f[11]) << 8 else { return nil }
        let end = len - 4
        let stored = UInt32(f[end]) | UInt32(f[end + 1]) << 8 | UInt32(f[end + 2]) << 16 | UInt32(f[end + 3]) << 24
        guard crc32(f[0..<end]) == stored else { return nil }
        return Frame(cmdSet: f[12], cmdID: f[13], cmdType: f[3],
                     seq: UInt16(f[8]) | UInt16(f[9]) << 8, payload: Array(f[14..<end]))
    }

    // MARK: Payloads

    /// Connection request (00/19), 33 bytes.
    /// `verifyMode` 1 = first pairing (the camera asks you to approve), 0 = already paired.
    public static func connectionRequest(deviceID: UInt32, mac: [UInt8], verifyMode: UInt8, verifyData: UInt16) -> [UInt8] {
        var p: [UInt8] = []
        p.appendLE(deviceID)
        p.append(UInt8(mac.count))
        p += mac + [UInt8](repeating: 0, count: 16 - mac.count)
        p.appendLE(UInt32(0))   // fw_version
        p.append(0)             // conidx
        p.append(verifyMode)
        p.appendLE(verifyData)
        p += [0, 0, 0, 0]
        return p
    }

    /// Our reply to the camera's own connection request (00/19, response), 9 bytes.
    public static func connectionResponse(deviceID: UInt32, retCode: UInt8 = 0, cameraIndex: UInt8 = 0) -> [UInt8] {
        var p: [UInt8] = []
        p.appendLE(deviceID)
        p += [retCode, cameraIndex, 0, 0, 0]
        return p
    }

    /// Camera status subscription (1D/05). Mode 3 = periodic plus on change; DJI fixes freq at 20 (2 Hz).
    public static func statusSubscription(pushMode: UInt8 = 3, pushFreq: UInt8 = 20) -> [UInt8] {
        [pushMode, pushFreq, 0, 0, 0, 0]
    }

    /// Record control (1D/03): start or stop recording.
    public static func recordControl(deviceID: UInt32, start: Bool) -> [UInt8] {
        var p: [UInt8] = []
        p.appendLE(deviceID)
        p.append(start ? 0 : 1)
        p += [0, 0, 0, 0]
        return p
    }

    // MARK: Decoding

    /// The camera's half of the handshake: a connection request with verify_mode 2.
    public enum ConnectionVerdict: Equatable { case approved, rejected, other(mode: UInt8) }

    public static func connectionVerdict(_ payload: [UInt8]) -> ConnectionVerdict? {
        guard payload.count >= 29 else { return nil }
        let mode = payload[26]
        guard mode == 2 else { return .other(mode: mode) }
        let data = UInt16(payload[27]) | UInt16(payload[28]) << 8
        return data == 0 ? .approved : .rejected
    }

    public struct CameraStatus: Equatable {
        public let mode: UInt8
        public let status: UInt8
        public let recordSeconds: Int
        public let battery: Int?

        /// Status 3 = recording (or taking a photo), 5 = pre-recording.
        public var isRecording: Bool { status == 0x03 || status == 0x05 }
        /// Mode 0x23 = UVC live streaming, the Pocket's webcam mode.
        public var isWebcamMode: Bool { mode == 0x23 }

        public var modeName: String {
            switch mode {
            case 0x00: "Slow motion"
            case 0x01: "Video"
            case 0x02: "Timelapse"
            case 0x05: "Photo"
            case 0x0A: "Hyperlapse"
            case 0x1A: "Live stream"
            case 0x23: "Webcam (UVC)"
            case 0x28: "SuperNight"
            case 0x34: "Tracking"
            default: String(format: "Mode 0x%02X", mode)
            }
        }
    }

    /// Camera status push (1D/02).
    public static func cameraStatus(_ p: [UInt8]) -> CameraStatus? {
        guard p.count >= 7 else { return nil }
        let battery: Int? = p.count >= 38 ? Int(p[37]) : nil
        return CameraStatus(mode: p[0], status: p[1],
                            recordSeconds: Int(UInt16(p[5]) | UInt16(p[6]) << 8),
                            battery: battery)
    }
}

/// Joins BLE notifications into whole frames. A frame may arrive split across notifications,
/// or several may arrive in one.
public struct RSDKFrameAssembler {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
        buffer += bytes
        var out: [[UInt8]] = []
        while true {
            // Drop bytes until a start-of-frame marker.
            if let start = buffer.firstIndex(of: 0xAA), start > 0 { buffer.removeFirst(start) }
            else if buffer.first != 0xAA { buffer.removeAll(); break }
            guard buffer.count >= 3 else { break }
            let len = Int(UInt16(buffer[1]) | UInt16(buffer[2]) << 8) & 0x3FF
            guard len >= 18 else { buffer.removeFirst(); continue }
            // Once the header is in, check its CRC so a stray 0xAA can't stall the buffer.
            if buffer.count >= 12,
               RSDK.crc16(buffer[0..<10]) != UInt16(buffer[10]) | UInt16(buffer[11]) << 8 {
                buffer.removeFirst(); continue
            }
            guard buffer.count >= len else { break }
            out.append(Array(buffer[0..<len]))
            buffer.removeFirst(len)
        }
        return out
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}
