import Foundation
import Network
import OsmoSyncCore

/// The Wi-Fi command link to an Osmo Pocket on the same network: a TCP poke on 7001 that
/// carries our pairing frame, then DUML over UDP on 9004. Steps follow OpenCine's datalink.
@MainActor
final class OsmoDatalink {
    enum Failure: LocalizedError {
        case pokeFailed, noHandshake, closed
        var errorDescription: String? {
            switch self {
            case .pokeFailed: "The camera didn't accept a connection on port 7001"
            case .noHandshake: "The camera didn't answer on its Wi-Fi link"
            case .closed: "The Wi-Fi link closed"
            }
        }
    }

    let host: String
    private let identifier: String
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "OsmoDatalink")

    private var tcp: NWConnection?
    private var udp: NWConnection?
    private var session: UInt16 = 0
    private var baseSeq: UInt16 = 0
    private var udpSeq: UInt16 = 0
    private var dumlSeq: UInt16 = 0xA000
    private var counter: UInt8 = 0
    private var handshakeAcked = false
    private var initialSeq: UInt16?
    private var videoCursor: UInt16?
    private var ackedCursor: UInt16?
    private var extraCursor: UInt16?
    private var ackTimer: Timer?
    private var presenceTimer: Timer?
    private var waiters: [(set: UInt8, id: UInt8, c: CheckedContinuation<DUML.Frame?, Never>)] = []
    private(set) var isOpen = false
    private(set) var lastHeard = Date.distantPast
    var trace = false
    /// Frames the camera sends on its own, such as the `0x02/0x80` status push.
    var onPush: ((DUML.Frame) -> Void)?

    init(host: String, identifier: String, log: @escaping (String) -> Void) {
        self.host = host
        self.identifier = identifier
        self.log = log
    }

    /// Poke, handshake and register. Throws if the camera never answers.
    func open() async throws {
        try await poke()
        session = UInt16.random(in: 0x1000...0xFFFE)
        baseSeq = UInt16.random(in: 0x1000...0xF000) & 0xFFF8
        udpSeq = 0
        let c = NWConnection(host: .init(host), port: .init(rawValue: DUMLDatalink.port)!, using: .udp)
        udp = c
        c.start(queue: queue)
        receive(on: c)
        for _ in 0..<20 where !(handshakeAcked && initialSeq != nil) {
            write(DUMLDatalink.handshake(session: session, seq: udpSeq, baseSeq: baseSeq))
            udpSeq &+= 8
            for _ in 0..<18 where !(handshakeAcked && initialSeq != nil) {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard handshakeAcked, let initial = initialSeq else { close(); throw Failure.noHandshake }
        udpSeq = initial
        isOpen = true
        log("Wi-Fi link open to \(host)")
        sendAck()
        send(DUML.appDeviceInfo(seq: 0)); sendAck()
        send(DUML.appPresence(seq: 0)); sendAck()
        ackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendAck() }
        }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(DUML.appPresence(seq: 0)) }
        }
    }

    func close() {
        isOpen = false
        ackTimer?.invalidate(); ackTimer = nil
        presenceTimer?.invalidate(); presenceTimer = nil
        udp?.cancel(); udp = nil
        tcp?.cancel(); tcp = nil
        for w in waiters { w.c.resume(returning: nil) }
        waiters = []
    }

    /// Sends a frame and waits for the camera's reply to the same command.
    func request(_ frame: DUML.Frame, timeout: Double) async -> DUML.Frame? {
        guard udp != nil else { return nil }
        return await withCheckedContinuation { c in
            waiters.append((frame.cmdSet, frame.cmdID, c))
            send(frame)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let i = self.waiters.firstIndex(where: { $0.set == frame.cmdSet && $0.id == frame.cmdID })
                else { return }
                self.waiters.remove(at: i).c.resume(returning: nil)
            }
        }
    }

    func send(_ frame: DUML.Frame) {
        guard udp != nil else { return }
        var f = frame
        f.seq = dumlSeq
        dumlSeq &+= 1
        counter &+= 1
        let pkt = DUMLDatalink.command(f, session: session, seq: udpSeq, counter: counter)
        udpSeq &+= 8
        if trace, !(f.cmdSet == 0 && f.cmdID == 0x88) {
            log(String(format: "WiFi TX %02X/%02X: ", f.cmdSet, f.cmdID) + OsmoCamera.hex(f.payload))
        }
        write(pkt)
    }

    // MARK: Internals

    private func poke() async throws {
        let c = NWConnection(host: .init(host), port: .init(rawValue: DUMLDatalink.pokePort)!, using: .tcp)
        tcp = c
        let ready = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            let finish: @Sendable (Bool) -> Void = { ok in if once.take() { k.resume(returning: ok) } }
            c.stateUpdateHandler = { s in
                switch s {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            c.start(queue: queue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
        }
        guard ready else { c.cancel(); tcp = nil; throw Failure.pokeFailed }
        c.send(content: Data(DUML.encode(DUML.setPairingPin(identifier: identifier))), completion: .idempotent)
        // The camera writes status frames here for the whole session; read and drop them.
        Self.drain(c)
        try? await Task.sleep(for: .milliseconds(400))
    }

    nonisolated private static func drain(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, complete, error in
            guard !complete, error == nil else { return }
            drain(c)
        }
    }

    private func write(_ bytes: [UInt8]) {
        udp?.send(content: Data(bytes), completion: .idempotent)
    }

    private func sendAck() {
        guard isOpen else { return }
        write(DUMLDatalink.ack(session: session, video: videoCursor ?? 0,
                               ackedData: ackedCursor ?? baseSeq, extra: extraCursor ?? baseSeq))
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            let bytes = data.map { [UInt8]($0) }
            DispatchQueue.main.async {
                guard let self, self.udp === c else { return }
                if let bytes { self.ingest(bytes) }
                if error == nil { self.receive(on: c) }
            }
        }
    }

    private func ingest(_ d: [UInt8]) {
        guard let type = DUMLDatalink.packetType(d) else { return }
        lastHeard = Date()
        switch type {
        case DUMLDatalink.PacketType.handshake.rawValue:
            handshakeAcked = true
        case DUMLDatalink.PacketType.telemetry.rawValue:
            if initialSeq == nil { initialSeq = DUMLDatalink.commandSeq(fromInitialWindow: d) }
            if let w = DUMLDatalink.telemetryWindows(d) {
                if ackedCursor.map({ DUMLDatalink.isForward(w.ackedData, from: $0) }) ?? true { ackedCursor = w.ackedData }
                extraCursor = w.extra
            }
        case DUMLDatalink.PacketType.video.rawValue:
            videoCursor = DUMLDatalink.transportSeq(d)
        case DUMLDatalink.PacketType.ackedData.rawValue:
            if let s = DUMLDatalink.transportSeq(d), ackedCursor.map({ DUMLDatalink.isForward(s, from: $0) }) ?? true {
                ackedCursor = s
            }
        default:
            break
        }
        for f in DUMLDatalink.frames(in: d) where !f.isResponse { onPush?(f) }
        for f in DUMLDatalink.frames(in: d) where f.isResponse {
            if trace, !(f.cmdSet == 0 && (f.cmdID == 0x88 || f.cmdID == 0x81)) {
                log(String(format: "WiFi RX %02X/%02X: ", f.cmdSet, f.cmdID) + OsmoCamera.hex(f.payload))
            }
            if let i = waiters.firstIndex(where: { $0.set == f.cmdSet && $0.id == f.cmdID }) {
                waiters.remove(at: i).c.resume(returning: f)
            }
        }
    }
}

/// Finds the camera on the Mac's own network: hosts that accept TCP on 7001.
enum OsmoLANScan {
    /// The Mac's IPv4 address and netmask on its Wi-Fi or Ethernet.
    static func localNetwork() -> (address: String, mask: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: (String, String, Int)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = ifa.ifa_netmask,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            func str(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                return String(cString: buf)
            }
            let rank = name == "en0" ? 0 : 1
            if best == nil || rank < best!.2 { best = (str(addr), str(mask), rank) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Up to 8 hosts answering on 7001, probing 64 at a time.
    static func candidates() async -> [String] {
        guard let net = localNetwork(), let hosts = DUMLStation.hosts(address: net.address, mask: net.mask) else { return [] }
        var found: [String] = []
        for start in stride(from: 0, to: hosts.count, by: 64) {
            let batch = hosts[start..<min(start + 64, hosts.count)]
            await withTaskGroup(of: String?.self) { g in
                for h in batch { g.addTask { await probe(h) ? h : nil } }
                for await h in g { if let h { found.append(h) } }
            }
            if found.count >= 8 { break }
        }
        return Array(found.prefix(8))
    }

    static func probe(_ host: String) async -> Bool {
        let c = NWConnection(host: .init(host), port: .init(rawValue: DUMLDatalink.pokePort)!, using: .tcp)
        defer { c.cancel() }
        return await withCheckedContinuation { k in
            let once = OnceFlag()
            c.stateUpdateHandler = { s in
                switch s {
                case .ready: if once.take() { k.resume(returning: true) }
                case .failed, .cancelled: if once.take() { k.resume(returning: false) }
                default: break
                }
            }
            c.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { if once.take() { k.resume(returning: false) } }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
