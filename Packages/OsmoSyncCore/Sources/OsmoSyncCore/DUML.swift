import Foundation

/// DJI's DUML framing, which Osmo Pocket cameras speak over Bluetooth (service FFF0).
/// Layout follows the open-source OpenCine / Osmosis work:
///
///     55 | len_lo | (1<<2)|len_hi | crc8(bytes 0..2) |
///     sender | receiver | seq:u16le | flags | cmdSet | cmdId | payload | crc16:u16le
public enum DUML {
    public static let senderApp: UInt8 = 0x02
    public static let rxCamera: UInt8 = 0x01
    public static let rxWifi: UInt8 = 0x07
    public static let rxSession: UInt8 = 0xF0

    public static let flagRequest: UInt8 = 0x40
    public static let flagResponse: UInt8 = 0xC0

    /// The token shown on the camera's screen when it asks you to approve.
    public static let pairingToken = "osmo"

    public struct Frame: Equatable {
        public var sender: UInt8
        public var receiver: UInt8
        public var seq: UInt16
        public var flags: UInt8
        public var cmdSet: UInt8
        public var cmdID: UInt8
        public var payload: [UInt8]

        public init(sender: UInt8 = DUML.senderApp, receiver: UInt8, seq: UInt16, flags: UInt8,
                    cmdSet: UInt8, cmdID: UInt8, payload: [UInt8]) {
            self.sender = sender; self.receiver = receiver; self.seq = seq; self.flags = flags
            self.cmdSet = cmdSet; self.cmdID = cmdID; self.payload = payload
        }

        public var isResponse: Bool { flags & 0x80 != 0 }
    }

    public static func crc8(_ data: ArraySlice<UInt8>) -> UInt8 {
        var c: UInt8 = 0x77
        for b in data {
            c ^= b
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8C : c >> 1 }
        }
        return c
    }

    public static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0x3692
        for b in data {
            c ^= UInt16(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x8408 : c >> 1 }
        }
        return c
    }

    public static func encode(_ f: Frame) -> [UInt8] {
        let total = 13 + f.payload.count
        var b: [UInt8] = [0x55, UInt8(total & 0xFF), UInt8((1 << 2) | ((total >> 8) & 0x03))]
        b.append(crc8(b[0..<3]))
        b += [f.sender, f.receiver, UInt8(f.seq & 0xFF), UInt8(f.seq >> 8), f.flags, f.cmdSet, f.cmdID]
        b += f.payload
        let c = crc16(b[...])
        b += [UInt8(c & 0xFF), UInt8(c >> 8)]
        return b
    }

    /// Length of a frame whose header starts at `b[0]`, or nil if the header is bad.
    static func frameLength(_ b: ArraySlice<UInt8>) -> Int? {
        guard b.count >= 4, b.first == 0x55 else { return nil }
        let s = b.startIndex
        guard crc8(b[s..<s + 3]) == b[s + 3] else { return nil }
        let n = Int(b[s + 1]) | (Int(b[s + 2] & 0x03) << 8)
        return n >= 13 ? n : nil
    }

    public static func parse(_ b: [UInt8]) -> Frame? {
        guard let n = frameLength(b[...]), b.count == n else { return nil }
        let c = UInt16(b[n - 2]) | UInt16(b[n - 1]) << 8
        guard crc16(b[0..<n - 2]) == c else { return nil }
        return Frame(sender: b[4], receiver: b[5], seq: UInt16(b[6]) | UInt16(b[7]) << 8, flags: b[8],
                     cmdSet: b[9], cmdID: b[10], payload: Array(b[11..<n - 2]))
    }

    static func packString(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        return [UInt8(u.count)] + u
    }

    // MARK: Commands

    /// `0x00/0x2B` session ping. `04 00` wakes the camera before pairing.
    public static func sessionWake(seq: UInt16 = 0x802B) -> Frame {
        Frame(receiver: rxSession, seq: seq, flags: flagRequest, cmdSet: 0x00, cmdID: 0x2B, payload: [0x04, 0x00])
    }

    /// `0x00/0x2B` `01 01`, sent about once a second to keep the link up.
    public static func sessionKeepalive(seq: UInt16 = 0x802B) -> Frame {
        Frame(receiver: rxSession, seq: seq, flags: flagRequest, cmdSet: 0x00, cmdID: 0x2B, payload: [0x01, 0x01])
    }

    /// `0x07/0x45` SetPairingPIN. Reply `00 01` = already paired, `00 02` = approve on the camera.
    public static func setPairingPin(identifier: String, seq: UInt16 = 0x8092) -> Frame {
        Frame(receiver: rxWifi, seq: seq, flags: flagRequest, cmdSet: 0x07, cmdID: 0x45,
              payload: packString(identifier) + packString(pairingToken))
    }

    /// The camera's approval arrives as a `0x07/0x46` request; answer with this.
    public static func pairApprovalAck(seq: UInt16) -> Frame {
        Frame(receiver: rxWifi, seq: seq, flags: flagResponse, cmdSet: 0x07, cmdID: 0x46, payload: [0x00])
    }

    /// `0x02/0x02` record. Payload `01` starts, `00` stops. Not a toggle.
    public static func record(start: Bool, seq: UInt16) -> Frame {
        Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0x02, payload: [start ? 1 : 0])
    }

    /// Receiver byte from a module type and index.
    public static func rx(type: UInt8, index: UInt8) -> UInt8 { index << 5 | type }

    /// `0x07/0x07` reads the camera's own hotspot name. The reply doubles as its identity on the network.
    public static func getWiFiName(seq: UInt16 = 0x8007) -> Frame {
        Frame(receiver: rxWifi, seq: seq, flags: flagRequest, cmdSet: 0x07, cmdID: 0x07, payload: [])
    }

    /// `0x07/0x39` asks which Wi-Fi role the camera is in. See `DUMLStation.role`.
    public static func wifiRole(seq: UInt16) -> Frame {
        Frame(receiver: rxWifi, seq: seq, flags: flagRequest, cmdSet: 0x07, cmdID: 0x39, payload: [0])
    }

    /// `0x07/0x48` switches between joining your Wi-Fi (`true`) and running its own hotspot.
    public static func stationMode(_ on: Bool, seq: UInt16) -> Frame {
        Frame(receiver: rxWifi, seq: seq, flags: flagRequest, cmdSet: 0x07, cmdID: 0x48, payload: [on ? 1 : 0])
    }

    /// `0x02/0xE1` to receiver 8: video shooting mode. Sent before joining Wi-Fi.
    public static func videoMode(seq: UInt16) -> Frame {
        Frame(receiver: 0x08, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0xE1, payload: [1])
    }

    /// `0x07/0x47` joins a Wi-Fi network. Nil if the name or password is too long.
    public static func joinWiFi(ssid: String, password: String, seq: UInt16) -> Frame? {
        guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 63 else { return nil }
        return Frame(receiver: rxWifi, seq: seq, flags: flagRequest, cmdSet: 0x07, cmdID: 0x47,
                     payload: packString(ssid) + packString(password))
    }

    // MARK: Wi-Fi link registration

    /// `0x00/0x81` app device info, sent once after the UDP handshake.
    public static func appDeviceInfo(seq: UInt16) -> Frame {
        var b = [UInt8](repeating: 0, count: 62)
        b[1] = 0x41; b[2] = 0x50; b[3] = 0x50  // "APP"
        b[41] = 0x02
        b[50] = 0x02
        b[51] = 0x08
        return Frame(receiver: rx(type: 0x08, index: 2), seq: seq, flags: 0x80, cmdSet: 0x00, cmdID: 0x81, payload: b)
    }

    /// `0x00/0x88` app presence, about once a second to hold the session open.
    public static func appPresence(seq: UInt16) -> Frame {
        Frame(receiver: rx(type: 0x08, index: 1), seq: seq, flags: flagRequest, cmdSet: 0x00, cmdID: 0x88,
              payload: [0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
    }

    public enum PairingReply: Equatable { case alreadyPaired, needsApproval, deferred, other(UInt8) }

    public static func pairingReply(_ payload: [UInt8]) -> PairingReply {
        guard payload.count >= 2 else { return .other(255) }
        switch payload[1] {
        case 0x01: return .alreadyPaired
        case 0x02: return .needsApproval
        case 0x06: return .deferred
        default: return .other(payload[1])
        }
    }
}

/// Collects DUML frames from Bluetooth notifications, which can split or join frames.
public struct DUMLFrameAssembler {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
        buf += bytes
        var out: [[UInt8]] = []
        while true {
            guard let start = buf.firstIndex(of: 0x55) else { buf.removeAll(); break }
            if start > 0 { buf.removeFirst(start) }
            if buf.count < 4 { break }
            guard let n = DUML.frameLength(buf[...]) else { buf.removeFirst(); continue }
            if buf.count < n { break }
            out.append(Array(buf[0..<n]))
            buf.removeFirst(n)
        }
        return out
    }
}
