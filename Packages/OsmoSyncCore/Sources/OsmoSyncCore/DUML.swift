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

    /// `0x07/0x0E` reads the camera's own hotspot password. Reply: `[status][len][bytes]`.
    public static func getWiFiPassword(seq: UInt16) -> Frame {
        Frame(receiver: rxWifi, seq: seq, flags: flagRequest, cmdSet: 0x07, cmdID: 0x0E, payload: [])
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

    /// `0x02/0x0C` enter (`01 01 00 01`) or leave (`01 01 00 00`) playback.
    public static func playback(_ enter: Bool, seq: UInt16) -> Frame {
        Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0x0C,
              payload: [1, 1, 0, enter ? 1 : 0])
    }

    /// `0x00/0x26` media list page for one store (SD: counter 1, cursor 1). Replies arrive
    /// as `0x00/0x27` pushes. Payload template from OpenCine / Osmosis.
    public static func mediaList(counter: UInt8, cursor: UInt32, seq: UInt16) -> Frame {
        var p: [UInt8] = [0x4A, 0x00, 0x2A, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                          0x2D, 0x00, 0x0D, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                          0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        p[4] = counter
        for i in 0..<4 { p[10 + i] = UInt8((cursor >> (8 * UInt32(i))) & 0xFF) }
        return Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x00, cmdID: 0x26, payload: p)
    }

    /// `0x00/0x28` deletes files by media-list handle. Irreversible. The camera only answers
    /// while in playback. Payload `[n][handle u32-LE × n][n u32] 00 [n u32] 01 01 00 00`,
    /// from OpenCine / OsmoOffload (MIT).
    public static func deleteFiles(handles: [UInt32], seq: UInt16) -> Frame {
        let n = UInt32(handles.count)
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        var p: [UInt8] = [UInt8(truncatingIfNeeded: n)]
        for h in handles { p += le(h) }
        p += le(n) + [0] + le(n) + [1, 1, 0, 0]
        return Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x00, cmdID: 0x28, payload: p)
    }

    /// The status word in a delete reply: `0x0000` done, `0x00D6` no such file.
    public static func deleteStatus(_ payload: [UInt8]) -> UInt16? {
        guard let first = payload.first else { return nil }
        return payload.count >= 2 ? UInt16(first) | UInt16(payload[1]) << 8 : UInt16(first)
    }

    /// `0x00/0x26` stream trigger, sent between list queries.
    public static func mediaListTrigger(seq: UInt16) -> Frame {
        Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x00, cmdID: 0x26,
              payload: [0x4A, 0x04, 0x0E, 0x10, 0x01, 0, 0, 0, 0, 0, 0x01, 0, 0, 0])
    }

    // MARK: Gimbal and zoom (from OpenCine's captures of DJI Mimo)

    public static let rxGimbal: UInt8 = 0x04

    /// `0x04/0x01` virtual joystick, sent about 25 times a second while held, with no reply.
    /// `tilt` and `pan` run −1…1 (down/left to up/right) and set the speed, not the angle.
    public static func gimbalStick(tilt: Double, pan: Double, seq: UInt16) -> Frame {
        let t = GimbalStick.axis(tilt), p = GimbalStick.axis(pan)
        let payload: [UInt8] = [UInt8(t & 0xFF), UInt8(t >> 8), 0, 0, UInt8(p & 0xFF), UInt8(p >> 8), 0x00, 0x80, 0x22, 0x00]
        return Frame(receiver: rxGimbal, seq: seq, flags: 0x00, cmdSet: 0x04, cmdID: 0x01, payload: payload)
    }

    /// `0x04/0x4C` `FE 08`: point the gimbal straight ahead again.
    public static func gimbalRecentre(seq: UInt16) -> Frame {
        Frame(receiver: rxGimbal, seq: seq, flags: flagRequest, cmdSet: 0x04, cmdID: 0x4C, payload: [0xFE, 0x08])
    }

    /// `0x02/0xB8` `0A 4E` + lens position: jump to a zoom factor.
    public static func zoom(factor: Double, seq: UInt16) -> Frame {
        let lens = Zoom.lensPosition(for: factor)
        return Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0xB8,
                     payload: [0x0A, 0x4E, UInt8(lens & 0xFF), UInt8(lens >> 8)])
    }

    // MARK: Subject tracking and focus (from OpenCine's captures of DJI Mimo)

    /// `0x02/0xA6`: track whatever is inside a box. `01 00 00`, a u16-LE request id, then the
    /// box as four f32-LE values, 0…1 of the frame: centre x, centre y, width, height.
    public static func trackSubject(id: UInt16, centreX: Float, centreY: Float, width: Float, height: Float,
                                    seq: UInt16) -> Frame {
        let p: [UInt8] = [0x01, 0x00, 0x00, UInt8(id & 0xFF), UInt8(id >> 8)]
            + floatLE(centreX) + floatLE(centreY) + floatLE(width) + floatLE(height)
        return Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0xA6, payload: p)
    }

    /// `0x02/0xA6` with 21 zero bytes: stop tracking.
    public static func stopTracking(seq: UInt16) -> Frame {
        Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0xA6,
              payload: [UInt8](repeating: 0, count: 21))
    }

    /// `0x02/0xA5` `00`: is the camera tracking? Reply `00 01 00 00` locked, `00 00 00 00` idle.
    public static func trackingState(seq: UInt16) -> Frame {
        Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0xA5, payload: [0x00])
    }

    public static func isTrackingLocked(_ reply: [UInt8]) -> Bool {
        reply.count >= 4 && reply[0] == 0 && reply[1] == 0x01
    }

    /// Mimo's tap-to-focus burst, in order: spot metering, focus point, AE hint, metering point.
    /// `x` and `y` run 0…1 across the frame. The camera needs all four; two alone time out.
    public static func focus(x: Float, y: Float, seq: UInt16) -> [Frame] {
        [
            Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0x22, payload: [0x02]),
            Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0x30,
                  payload: floatLE(x) + floatLE(y) + [UInt8](repeating: 0, count: 13)),
            Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0x68, payload: [0x08]),
            Frame(receiver: rxCamera, seq: seq, flags: flagRequest, cmdSet: 0x02, cmdID: 0x32,
                  payload: [0x00, 0x02, 0x01, 0x00] + floatLE(x) + floatLE(y) + [UInt8](repeating: 0, count: 8)),
        ]
    }

    static func floatLE(_ v: Float) -> [UInt8] {
        let b = v.bitPattern
        return [UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8(b >> 24)]
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

/// Joystick values for `DUML.gimbalStick`: centre 1024, travel ±550. The camera drops
/// frames outside 474…1574 rather than clamping them, so stay inside.
public enum GimbalStick {
    public static let centre: UInt16 = 1024
    public static let travel = 550.0
    /// Small pushes count as rest, so the gimbal doesn't creep.
    public static let deadzone = 0.08

    public static func axis(_ v: Double) -> UInt16 {
        guard v.isFinite, abs(v) > deadzone else { return centre }
        let c = min(max(v, -1), 1)
        return UInt16((Double(centre) + c * travel).rounded())
    }
}

/// Zoom factor to the camera's lens position: 217 is 1×, 651 is 3× (where the Pocket 4P
/// switches to its telephoto camera), 2604 is 12×, straight lines between. The camera
/// clamps to what the current resolution allows.
public enum Zoom {
    public static let range = 1.0...12.0
    static let lens1x = 217.0, lens3x = 651.0, lens12x = 2604.0

    public static func lensPosition(for factor: Double) -> UInt16 {
        let f = min(max(factor.isFinite ? factor : 1, range.lowerBound), range.upperBound)
        let v = f <= 3 ? lens1x + (f - 1) / 2 * (lens3x - lens1x) : lens3x + (f - 3) / 9 * (lens12x - lens3x)
        return UInt16(v.rounded())
    }
}
