import Foundation

/// DUML over UDP: how Osmo Pocket cameras take commands over Wi-Fi (port 9004 on the
/// Pocket 4 Pro). Layout follows OpenCine's `DumlTransport` (from the Osmosis captures).
///
/// Each datagram is `[8-byte transport header][payload]`. Commands (packet type 0x05) carry
/// a 12-byte routing header and then a normal DUML frame.
public enum DUMLDatalink {
    public static let port: UInt16 = 9004
    /// The camera wants a TCP connection here, carrying the pairing frame, before UDP.
    public static let pokePort: UInt16 = 7001

    public enum PacketType: UInt8 {
        case handshake = 0x00
        case telemetry = 0x01
        case video = 0x02
        case ackedData = 0x03
        case ack = 0x04
        case command = 0x05
    }

    /// `[u16le 0x8000|total][u16le session][u16le seq][type][xor of the first seven]`.
    public static func transportHeader(type: UInt8, payloadLength: Int, session: UInt16, seq: UInt16) -> [UInt8] {
        let w0 = 0x8000 | ((8 + payloadLength) & 0x3FFF)
        var b: [UInt8] = [UInt8(w0 & 0xFF), UInt8(w0 >> 8),
                          UInt8(session & 0xFF), UInt8(session >> 8),
                          UInt8(seq & 0xFF), UInt8(seq >> 8), type]
        b.append(b.reduce(0, ^))
        return b
    }

    /// `[u16le seq-8][u16le seq][00 00 00 00][counter][01][00][00]`, both in our own UDP seq space.
    public static func routingHeader(seq: UInt16, counter: UInt8) -> [UInt8] {
        let prev = seq &- 8
        return [UInt8(prev & 0xFF), UInt8(prev >> 8), UInt8(seq & 0xFF), UInt8(seq >> 8),
                0, 0, 0, 0, counter, 0x01, 0, 0]
    }

    /// The 40-byte session-open payload. `baseSeq` should be random and a multiple of 8.
    public static func handshakePayload(baseSeq: UInt16) -> [UInt8] {
        var p: [UInt8] = [
            0x00, 0x00, 0x64, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x00, 0x01, 0x90,
            0x01, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x14, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00,
            0x00, 0x64, 0x00, 0x01, 0x01, 0x04, 0x01, 0x02,
        ]
        p[0] = UInt8(baseSeq & 0xFF)
        p[1] = UInt8(baseSeq >> 8)
        return p
    }

    public static func handshake(session: UInt16, seq: UInt16, baseSeq: UInt16) -> [UInt8] {
        let p = handshakePayload(baseSeq: baseSeq)
        return transportHeader(type: PacketType.handshake.rawValue, payloadLength: p.count, session: session, seq: seq) + p
    }

    /// A DUML frame wrapped for the wire.
    public static func command(_ frame: DUML.Frame, session: UInt16, seq: UInt16, counter: UInt8) -> [UInt8] {
        let body = routingHeader(seq: seq, counter: counter) + DUML.encode(frame)
        return transportHeader(type: PacketType.command.rawValue, payloadLength: body.count, session: session, seq: seq) + body
    }

    /// The 26-byte window ACK: three groups of `[v v 0 0 0 0]` (v as u16le twice) and `00 00`.
    public static func ackPayload(video: UInt16, ackedData: UInt16, extra: UInt16) -> [UInt8] {
        func group(_ v: UInt16) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8(v >> 8), UInt8(v & 0xFF), UInt8(v >> 8), 0, 0, 0, 0]
        }
        return group(video) + group(ackedData) + group(extra) + [0, 0]
    }

    public static func ack(session: UInt16, video: UInt16, ackedData: UInt16, extra: UInt16) -> [UInt8] {
        let p = ackPayload(video: video, ackedData: ackedData, extra: extra)
        return transportHeader(type: PacketType.ack.rawValue, payloadLength: p.count, session: session, seq: 0) + p
    }

    public static func packetType(_ d: [UInt8]) -> UInt8? { d.count >= 8 ? d[6] : nil }

    public static func transportSeq(_ d: [UInt8]) -> UInt16? {
        d.count >= 6 ? UInt16(d[4]) | UInt16(d[5]) << 8 : nil
    }

    /// The first 34-byte telemetry packet after the handshake sets where our command seq starts.
    public static func commandSeq(fromInitialWindow d: [UInt8]) -> UInt16? {
        guard d.count == 34, d[6] == PacketType.telemetry.rawValue else { return nil }
        return (UInt16(d[8]) | UInt16(d[9]) << 8) &+ 8
    }

    /// Window cursors the camera reports in 34-byte telemetry (ackedData, extra).
    public static func telemetryWindows(_ d: [UInt8]) -> (ackedData: UInt16, extra: UInt16)? {
        guard d.count >= 34, d[6] == PacketType.telemetry.rawValue else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(d[i]) | UInt16(d[i + 1]) << 8 }
        return (u16(18), u16(26))
    }

    /// True when `candidate` is ahead of `current` on the u16 ring.
    public static func isForward(_ candidate: UInt16, from current: UInt16) -> Bool {
        let delta = candidate &- current
        return delta != 0 && delta < 0x8000
    }

    /// Every CRC-valid DUML frame inside a datagram.
    public static func frames(in raw: [UInt8]) -> [DUML.Frame] {
        var out: [DUML.Frame] = []
        var i = 0
        while i + 13 <= raw.count {
            if raw[i] == 0x55, let n = DUML.frameLength(raw[i...]), i + n <= raw.count,
               let f = DUML.parse(Array(raw[i..<i + n])) {
                out.append(f)
                i += n
            } else {
                i += 1
            }
        }
        return out
    }
}

/// Moving a Pocket off its own hotspot and onto your Wi-Fi, over Bluetooth. Order and reply
/// shapes as captured on a Pocket 4 Pro by OpenCine (`StationJoin`, `MulticamCommands`).
public enum DUMLStation {
    public enum Role: Equatable { case station, accessPoint, unknown }

    /// Reply to `wifiWorkMode`: `00 01` = on your Wi-Fi, `00 00` = its own hotspot.
    public static func role(_ reply: [UInt8]) -> Role {
        switch reply {
        case [0, 1]: .station
        case [0, 0]: .accessPoint
        default: .unknown
        }
    }

    public enum JoinResult: Equatable { case joined, retry, rejected }

    /// Reply to `joinWiFi`. `01 FF` happens while the radio switches; worth another try.
    public static func joinResult(_ reply: [UInt8], attempt: Int, maxAttempts: Int = 3) -> JoinResult {
        if reply == [0, 0] || reply == [0, 0, 0] { return .joined }
        if reply == [1, 0xFF], attempt < maxAttempts { return .retry }
        return .rejected
    }

    /// Every host address on the Mac's subnet, except the Mac. Nil for a subnet over 1,022 hosts.
    public static func hosts(address: String, mask: String) -> [String]? {
        func parse(_ s: String) -> UInt32? {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var v: UInt32 = 0
            for p in parts {
                guard let b = UInt8(p) else { return nil }
                v = v << 8 | UInt32(b)
            }
            return v
        }
        guard let ip = parse(address), let m = parse(mask) else { return nil }
        let hostBits = ~m
        guard hostBits > 1, hostBits <= 1023, hostBits & (hostBits &+ 1) == 0 else { return nil }
        let net = ip & m
        return (1..<hostBits).compactMap { off in
            let v = net | off
            return v == ip ? nil : [24, 16, 8, 0].map { String((v >> $0) & 255) }.joined(separator: ".")
        }
    }
}
