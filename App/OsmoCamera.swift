import CoreBluetooth
import Foundation
import OsmoSyncCore
import os

private let logger = Logger(subsystem: "com.ssharples.OsmoSync", category: "app")

/// Talks to an Osmo camera over Bluetooth: pair once (approve on the camera's screen),
/// then start and stop recording. Osmo Pocket cameras speak DUML; Action and 360
/// cameras speak DJI's published R-SDK.
@MainActor
final class OsmoCamera: NSObject, ObservableObject {
    enum State: Equatable {
        case bluetoothOff
        case notAllowed
        case idle
        case scanning
        case connecting(String)
        case waitingForApproval(String)
        case ready(String)
        case failed(String)

        var label: String {
            switch self {
            case .bluetoothOff: "Bluetooth is off"
            case .notAllowed: "Bluetooth access not allowed"
            case .idle: "Not connected"
            case .scanning: "Looking for camera…"
            case .connecting(let n): "Connecting to \(n)…"
            case .waitingForApproval(let n): "Approve OsmoSync on \(n)'s screen"
            case .ready(let n): "Connected to \(n)"
            case .failed(let why): why
            }
        }

        var isReady: Bool { if case .ready = self { true } else { false } }
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var status: RSDK.CameraStatus?
    @Published private(set) var log: [String] = []

    var onRecordingChanged: ((Bool) -> Void)?
    /// Logs every frame sent and received. On with `--probe`.
    var trace = false
    private var seenNames: Set<String> = []

    private static let service = CBUUID(string: "FFF0")
    private static let notifyChar = CBUUID(string: "FFF4")
    private static let writeChar = CBUUID(string: "FFF5")
    /// DJI's demo sends record control with this device id.
    private static let recordDeviceID: UInt32 = 0x33FF_0000

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeTarget: CBCharacteristic?
    private var assemblers: [CBUUID: RSDKFrameAssembler] = [:]
    private var seq: UInt16 = 0
    private var pendingNotify = 0
    private var approvalTimer: Timer?
    private var statusTimer: Timer?
    private var lastStatusAt = Date.distantPast
    private var recordWaiters: [UInt16: CheckedContinuation<Bool, Never>] = [:]
    private var wantConnection = false

    // DUML (Osmo Pocket) state
    private var useDUML = false
    private var notifyTarget: CBCharacteristic?
    private var dumlAssemblers: [CBUUID: DUMLFrameAssembler] = [:]
    private var dumlSeq: UInt16 = 0x8100
    private var writeQueue: [Data] = []
    private var writing = false
    private var keepaliveTimer: Timer?
    /// Pockets don't send a status feed over Bluetooth, so track recording from our own commands.
    @Published private(set) var dumlRecording = false
    private var bleWaiters: [(set: UInt8, id: UInt8, c: CheckedContinuation<DUML.Frame?, Never>)] = []

    // Wi-Fi link (Osmo Pocket on your home network)
    /// Short status line for the menu, e.g. "Camera on Wi-Fi at 192.168.1.40".
    @Published private(set) var wifiStatus = ""
    @Published private(set) var wifiBusy = false
    private(set) var datalink: OsmoDatalink?
    /// Home Wi-Fi name and password, or nil when not set up. Supplied by AppModel.
    var wifiCredentials: (() -> (ssid: String, password: String)?)?

    private let defaults = UserDefaults.standard

    /// The camera remembers a remote by device id and MAC, so keep both stable.
    private lazy var controllerID: UInt32 = {
        if let v = defaults.object(forKey: "controllerID") as? UInt32, v != 0 { return v }
        let v = UInt32.random(in: 1...UInt32.max) | 1
        defaults.set(v, forKey: "controllerID")
        return v
    }()

    private lazy var controllerMAC: [UInt8] = {
        if let d = defaults.data(forKey: "controllerMAC"), d.count == 6 { return [UInt8](d) }
        let m = (0..<6).map { _ in UInt8.random(in: 0...255) }
        defaults.set(Data(m), forKey: "controllerMAC")
        return m
    }()

    private var savedCameraID: UUID? {
        get { defaults.string(forKey: "cameraID").flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: "cameraID") }
    }

    /// The id the camera files its approval under, so it recognises us next time.
    private lazy var dumlIdentifier: String = {
        if let v = defaults.string(forKey: "dumlIdentifier"), v.count == 32 { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(v, forKey: "dumlIdentifier")
        return v
    }()

    /// The camera's hotspot-name reply, which proves a host on the LAN is this camera.
    private var wifiIdentity: [UInt8]? {
        get { defaults.data(forKey: "wifiIdentity").map { [UInt8]($0) } }
        set { defaults.set(newValue.map { Data($0) }, forKey: "wifiIdentity") }
    }

    private var lastHost: String? {
        get { defaults.string(forKey: "cameraHost") }
        set { defaults.set(newValue, forKey: "cameraHost") }
    }

    var wifiLinkOpen: Bool { datalink?.isOpen == true }

    private var pairedCameras: Set<String> {
        get { Set(defaults.stringArray(forKey: "pairedCameras") ?? []) }
        set { defaults.set(Array(newValue), forKey: "pairedCameras") }
    }

    var hasSavedCamera: Bool { savedCameraID != nil }
    var bluetoothOn: Bool { central.state == .poweredOn }
    var isRecording: Bool { useDUML ? dumlRecording : (status?.isRecording ?? false) }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Public controls

    func scan() {
        guard central.state == .poweredOn else { return }
        found = []
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("Scanning for Osmo cameras")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.state == .scanning else { return }
            self.central.stopScan()
            self.state = self.found.isEmpty ? .failed("No camera found. Turn the Osmo on and keep it close.") : .idle
        }
    }

    func connect(to id: UUID) {
        central.stopScan()
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            state = .failed("That camera is no longer in range")
            return
        }
        wantConnection = true
        savedCameraID = id
        open(p)
    }

    /// Reconnects to the camera paired last time, if any.
    func reconnect() {
        guard central.state == .poweredOn, let id = savedCameraID, peripheral == nil else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            wantConnection = true
            open(p)
        }
    }

    func disconnect(forget: Bool = false) {
        wantConnection = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        if forget { savedCameraID = nil }
        reset()
        state = .idle
    }

    /// Starts recording. Returns true when the camera confirms.
    @discardableResult
    func startRecording() async -> Bool { useDUML ? await sendDUMLRecord(start: true) : await sendRecord(start: true) }

    /// Stops recording. Returns true when the camera confirms.
    @discardableResult
    func stopRecording() async -> Bool { useDUML ? await sendDUMLRecord(start: false) : await sendRecord(start: false) }

    // MARK: Internals

    private func open(_ p: CBPeripheral) {
        reset()
        peripheral = p
        useDUML = Self.speaksDUML(p.name)
        p.delegate = self
        state = .connecting(p.name ?? "camera")
        central.connect(p)
        note("Connecting to \(p.name ?? p.identifier.uuidString)")
    }

    private func reset() {
        approvalTimer?.invalidate(); approvalTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        keepaliveTimer?.invalidate(); keepaliveTimer = nil
        writeTarget = nil
        notifyTarget = nil
        dumlAssemblers = [:]
        writeQueue = []
        writing = false
        dumlRecording = false
        assemblers = [:]
        pendingNotify = 0
        status = nil
        for (_, c) in recordWaiters { c.resume(returning: false) }
        recordWaiters = [:]
        for w in bleWaiters { w.c.resume(returning: nil) }
        bleWaiters = []
        peripheral = nil
    }

    private var name: String { peripheral?.name ?? "the camera" }

    private func nextSeq() -> UInt16 { seq = seq &+ 1; if seq == 0 { seq = 1 }; return seq }

    @discardableResult
    private func send(_ set: UInt8, _ id: UInt8, type: UInt8, payload: [UInt8], seq s: UInt16? = nil) -> UInt16 {
        let useSeq = s ?? nextSeq()
        guard let p = peripheral, let c = writeTarget else { return useSeq }
        let frame = RSDK.frame(cmdSet: set, cmdID: id, cmdType: type, payload: payload, seq: useSeq)
        if trace { note(String(format: "TX %02X/%02X type %02X seq %d: ", set, id, type, useSeq) + Self.hex(frame)) }
        p.writeValue(Data(frame), for: c, type: .withoutResponse)
        return useSeq
    }

    private func beginHandshake() {
        guard let p = peripheral else { return }
        let paired = pairedCameras.contains(p.identifier.uuidString)
        state = .waitingForApproval(name)
        note(paired ? "Asking camera to reconnect" : "Pairing: approve the request on the camera's screen")
        send(RSDK.setGeneral, RSDK.idConnection, type: RSDK.cmdWaitResult,
             payload: RSDK.connectionRequest(deviceID: controllerID, mac: controllerMAC,
                                             verifyMode: paired ? 0 : 1,
                                             verifyData: UInt16.random(in: 0..<10_000)))
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fail("The camera didn't approve the connection. Try again and tap OK on its screen.") }
        }
    }

    private func handle(_ f: RSDK.Frame) {
        switch (f.cmdSet, f.cmdID) {
        case (RSDK.setGeneral, RSDK.idConnection):
            handleConnection(f)
        case (RSDK.setCamera, RSDK.idStatusPush):
            guard let s = RSDK.cameraStatus(f.payload) else { return }
            lastStatusAt = Date()
            if trace, s != status { note("Status: \(s.modeName), recording \(s.isRecording), battery \(s.battery.map(String.init) ?? "?")%") }
            let was = status?.isRecording
            status = s
            if was != s.isRecording { onRecordingChanged?(s.isRecording) }
        case (RSDK.setCamera, RSDK.idRecordControl) where f.isResponse:
            let ok = f.payload.first == 0
            if !ok { note("Camera refused record command (code \(f.payload.first ?? 255))") }
            recordWaiters.removeValue(forKey: f.seq)?.resume(returning: ok)
        default:
            break
        }
    }

    private func handleConnection(_ f: RSDK.Frame) {
        if state.isReady { return }
        if f.isResponse {
            if f.payload.count > 4, f.payload[4] != 0 { fail("The camera refused the connection (code \(f.payload[4]))") }
            return
        }
        switch RSDK.connectionVerdict(f.payload) {
        case .approved:
            approvalTimer?.invalidate(); approvalTimer = nil
            send(RSDK.setGeneral, RSDK.idConnection, type: RSDK.ackNoResponse,
                 payload: RSDK.connectionResponse(deviceID: controllerID), seq: f.seq)
            if let p = peripheral { pairedCameras.insert(p.identifier.uuidString) }
            state = .ready(name)
            note("Connected to \(name)")
            subscribeStatus()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state.isReady else { return }
                    // Some cameras answer the subscription once and then go quiet; ask again.
                    if Date().timeIntervalSince(self.lastStatusAt) > 2 { self.subscribeStatus() }
                }
            }
        case .rejected:
            if let p = peripheral { pairedCameras.remove(p.identifier.uuidString) }
            fail("The camera rejected the connection")
        default:
            break
        }
    }

    private func subscribeStatus() {
        send(RSDK.setCamera, RSDK.idStatusSubscribe, type: RSDK.cmdNoResponse, payload: RSDK.statusSubscription())
    }

    private func sendRecord(start: Bool) async -> Bool {
        guard state.isReady else {
            note("Can't \(start ? "start" : "stop") recording: camera not connected")
            return false
        }
        if start && status?.isRecording == true { return true }
        if !start && status?.isRecording == false { return true }
        if start && status?.isWebcamMode == true {
            note("The camera is in webcam mode and can't record to its card")
        }
        let s = send(RSDK.setCamera, RSDK.idRecordControl, type: RSDK.cmdResponseOrNot,
                     payload: RSDK.recordControl(deviceID: Self.recordDeviceID, start: start))
        note(start ? "Sent: start recording" : "Sent: stop recording")
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            recordWaiters[s] = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let c = self.recordWaiters.removeValue(forKey: s) else { return }
                // No reply. Fall back on the status feed to tell whether it worked.
                c.resume(returning: self.status.map { $0.isRecording == start } ?? false)
            }
        }
        note(ok ? (start ? "Camera is recording" : "Camera stopped") : "Camera did not confirm")
        return ok
    }

    // MARK: DUML (Osmo Pocket)

    static func speaksDUML(_ name: String?) -> Bool {
        (name ?? "").localizedCaseInsensitiveContains("pocket")
    }

    private func nextDUMLSeq() -> UInt16 { dumlSeq = dumlSeq &+ 1; if dumlSeq < 0x8100 { dumlSeq = 0x8100 }; return dumlSeq }

    /// Writes go out one at a time, 120 ms apart; the camera drops writes sent faster.
    private func sendDUML(_ f: DUML.Frame) {
        let bytes = DUML.encode(f)
        if trace, !(f.cmdSet == 0x00 && f.cmdID == 0x2B && f.payload == [1, 1]) {
            note(String(format: "TX %02X/%02X flags %02X seq %04X: ", f.cmdSet, f.cmdID, f.flags, f.seq) + Self.hex(bytes))
        }
        writeQueue.append(Data(bytes))
        pumpWrites()
    }

    private func pumpWrites() {
        guard !writing, !writeQueue.isEmpty, let p = peripheral, let c = writeTarget else { return }
        writing = true
        p.writeValue(writeQueue.removeFirst(), for: c, type: .withoutResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.writing = false
            self?.pumpWrites()
        }
    }

    /// Notifications are on; arm app pairing by writing 01 00 to FFF4.
    private func armDUMLPairing() {
        guard let p = peripheral, let n = notifyTarget else { return }
        note("Arming pairing")
        p.writeValue(Data([0x01, 0x00]), for: n, type: .withResponse)
    }

    private func beginDUMLHandshake() {
        state = .waitingForApproval(name)
        note("Pairing: approve the request on the camera's screen (it shows OSMO)")
        sendDUML(DUML.sessionWake())
        sendDUML(DUML.setPairingPin(identifier: dumlIdentifier))
        approvalTimer?.invalidate()
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fail("The camera didn't approve the connection. Try again and tap OK on its screen.") }
        }
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendDUML(DUML.sessionKeepalive()) }
        }
    }

    private func dumlReady() {
        guard !state.isReady else { return }
        approvalTimer?.invalidate(); approvalTimer = nil
        if let p = peripheral { pairedCameras.insert(p.identifier.uuidString) }
        state = .ready(name)
        note("Connected to \(name)")
        if !wifiLinkOpen, let creds = wifiCredentials?() {
            Task { await joinWiFi(ssid: creds.ssid, password: creds.password) }
        }
    }

    private func handleDUML(_ f: DUML.Frame) {
        if f.isResponse, let i = bleWaiters.firstIndex(where: { $0.set == f.cmdSet && $0.id == f.cmdID }) {
            if trace { note(String(format: "RX %02X/%02X: ", f.cmdSet, f.cmdID) + Self.hex(f.payload)) }
            bleWaiters.remove(at: i).c.resume(returning: f)
            return
        }
        switch (f.cmdSet, f.cmdID) {
        case (0x07, 0x45) where f.isResponse:
            switch DUML.pairingReply(f.payload) {
            case .alreadyPaired: dumlReady()
            case .needsApproval: note("Waiting for you to approve on the camera")
            case .deferred: fail("The camera is busy pairing. Try again in a few seconds.")
            case .other(let c): note("Pairing reply code \(c)")
            }
        case (0x07, 0x46) where !f.isResponse:
            sendDUML(DUML.pairApprovalAck(seq: f.seq))
            dumlReady()
        case (0x02, 0x02) where f.isResponse:
            let ok = f.payload.first == 0
            if !ok { note("Camera refused record command (code \(f.payload.first.map { String(format: "%02X", $0) } ?? "none"))") }
            recordWaiters.removeValue(forKey: f.seq)?.resume(returning: ok)
        default:
            if trace, !(f.cmdSet == 0x00 && f.cmdID == 0x2B) {
                note(String(format: "RX %02X/%02X flags %02X from %02X: ", f.cmdSet, f.cmdID, f.flags, f.sender) + Self.hex(f.payload))
            }
        }
    }

    /// Probe only: send a record frame with a chosen seq and receiver.
    func probeRecord(start: Bool, seq: UInt16, receiver: UInt8 = DUML.rxCamera) {
        var f = DUML.record(start: start, seq: seq)
        f.receiver = receiver
        sendDUML(f)
    }

    private func sendDUMLRecord(start: Bool) async -> Bool {
        // Over Bluetooth the Pocket ignores record commands; they only work on its Wi-Fi link.
        if !wifiLinkOpen || Date().timeIntervalSince(datalink?.lastHeard ?? .distantPast) > 5 {
            datalink?.close(); datalink = nil
            if wifiIdentity != nil { _ = await findOnNetwork(within: 8) }
        }
        guard let link = datalink, link.isOpen else {
            note("Can't \(start ? "start" : "stop") recording: the camera isn't on Wi-Fi")
            return false
        }
        note(start ? "Sent: start recording (Wi-Fi)" : "Sent: stop recording (Wi-Fi)")
        let reply = await link.request(DUML.record(start: start, seq: 0), timeout: 5)
        let code = reply?.payload.first
        // 0xDF answers "start" while already recording.
        let ok = code == 0 || (start && code == 0xDF)
        if let code, !ok { note(String(format: "Camera refused record command (code %02X)", code)) }
        if ok {
            dumlRecording = start
            onRecordingChanged?(start)
        }
        note(ok ? (start ? "Camera is recording" : "Camera stopped") : reply == nil ? "Camera did not confirm" : "Camera refused")
        return ok
    }

    // MARK: Wi-Fi (camera joins your network)

    private func bleRequest(_ f: DUML.Frame, timeout: Double) async -> DUML.Frame? {
        guard peripheral != nil else { return nil }
        return await withCheckedContinuation { c in
            bleWaiters.append((f.cmdSet, f.cmdID, c))
            sendDUML(f)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let i = self.bleWaiters.firstIndex(where: { $0.set == f.cmdSet && $0.id == f.cmdID }) else { return }
                self.bleWaiters.remove(at: i).c.resume(returning: nil)
            }
        }
    }

    private func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// Moves the camera onto your Wi-Fi over Bluetooth, then opens the Wi-Fi command link.
    /// Steps and reply shapes as captured on a Pocket 4 Pro by OpenCine.
    @discardableResult
    func joinWiFi(ssid: String, password: String) async -> Bool {
        guard useDUML, state.isReady, !wifiBusy else { return wifiLinkOpen }
        wifiBusy = true
        defer { wifiBusy = false }
        wifiStatus = "Reading camera identity"
        guard let id = await bleRequest(DUML.getWiFiName(seq: nextDUMLSeq()), timeout: 12)?.payload,
              id.count > 2, id[0] == 0 else {
            wifiStatus = "Camera didn't answer the Wi-Fi query"
            note(wifiStatus)
            return false
        }
        wifiIdentity = id
        sendDUML(DUML.videoMode(seq: nextDUMLSeq()))
        await pause(2)
        let roleReply = await bleRequest(DUML.wifiRole(seq: nextDUMLSeq()), timeout: 12)?.payload ?? []
        let role = DUMLStation.role(roleReply)
        note("Camera Wi-Fi role: \(role) (\(Self.hex(roleReply)))")
        if role == .station {
            wifiStatus = "Looking for the camera on \(ssid)"
            if await findOnNetwork(within: 15) { return true }
        } else {
            guard role == .accessPoint else {
                wifiStatus = "Camera didn't report its Wi-Fi mode"
                note(wifiStatus)
                return false
            }
            wifiStatus = "Switching camera to your Wi-Fi"
            let sw = await bleRequest(DUML.stationMode(true, seq: nextDUMLSeq()), timeout: 12)?.payload
            guard sw == [0, 0] else {
                wifiStatus = "Camera refused to join a network (\(Self.hex(sw ?? [])))"
                note(wifiStatus)
                return false
            }
            var switched = false
            for _ in 0..<6 {
                let r = await bleRequest(DUML.wifiRole(seq: nextDUMLSeq()), timeout: 12)?.payload ?? []
                if DUMLStation.role(r) == .station { switched = true; break }
                await pause(2)
            }
            guard switched else {
                wifiStatus = "Camera Wi-Fi is still starting. Try again."
                note(wifiStatus)
                return false
            }
        }
        wifiStatus = "Waiting for camera Wi-Fi"
        await pause(10)
        for attempt in 1...3 {
            wifiStatus = "Joining \(ssid) (try \(attempt) of 3)"
            note(wifiStatus)
            guard let join = DUML.joinWiFi(ssid: ssid, password: password, seq: nextDUMLSeq()) else {
                wifiStatus = "Wi-Fi name or password is too long"
                return false
            }
            guard let reply = await bleRequest(join, timeout: 45)?.payload else {
                // A lost Bluetooth reply doesn't mean the join failed.
                if await findOnNetwork(within: 0) { return true }
                await pause(5)
                continue
            }
            note("Join reply: \(Self.hex(Array(reply.prefix(4))))")
            switch DUMLStation.joinResult(reply, attempt: attempt) {
            case .joined:
                wifiStatus = "Camera joined \(ssid); finding it"
                if await findOnNetwork(within: 60) { return true }
                wifiStatus = "Camera joined \(ssid) but the Mac can't find it. Is the Mac on \(ssid)?"
                note(wifiStatus)
                return false
            case .retry:
                await pause(5)
            case .rejected:
                wifiStatus = "Camera couldn't join \(ssid). Check the password; WPA3-only networks can refuse it."
                note(wifiStatus)
                return false
            }
        }
        wifiStatus = "Camera Wi-Fi didn't respond. Keep it close and try again."
        note(wifiStatus)
        return false
    }

    /// Finds this camera on the Mac's network and opens the Wi-Fi link. Checks identity,
    /// so another DJI camera on the same network is never used by mistake.
    @discardableResult
    func findOnNetwork(within patience: Double) async -> Bool {
        guard let identity = wifiIdentity else { return false }
        let deadline = Date().addingTimeInterval(patience)
        repeat {
            var hosts = lastHost.map { [$0] } ?? []
            if let h = hosts.first, await !OsmoLANScan.probe(h) { hosts = [] }
            if hosts.isEmpty { hosts = await OsmoLANScan.candidates() }
            note("Wi-Fi scan: \(hosts.count) host\(hosts.count == 1 ? "" : "s") answering on 7001")
            for host in hosts {
                let link = OsmoDatalink(host: host, identifier: dumlIdentifier) { [weak self] in self?.note($0) }
                link.trace = trace
                do { try await link.open() } catch {
                    note("\(host): \(error.localizedDescription)")
                    continue
                }
                let reply = await link.request(DUML.getWiFiName(seq: 0), timeout: 8)
                guard reply?.payload == identity else {
                    note("\(host) is a different camera")
                    link.close()
                    continue
                }
                datalink?.close()
                datalink = link
                lastHost = host
                wifiStatus = "Camera on Wi-Fi at \(host)"
                note(wifiStatus)
                return true
            }
            if Date() >= deadline { break }
            await pause(2)
        } while Date() < deadline
        return false
    }

    func disconnectWiFi() {
        datalink?.close()
        datalink = nil
        wifiStatus = ""
    }

    private func fail(_ why: String) {
        note(why)
        wantConnection = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        reset()
        state = .failed(why)
    }

    func note(_ s: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logger.notice("\(s, privacy: .public)")
        log.append("\(stamp)  \(s)")
        Self.appendToFile("\(Date().ISO8601Format())  \(s)\n")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

extension OsmoCamera {
    /// ~/Library/Logs/OsmoSync.log, so a test run can be read afterwards.
    static let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OsmoSync.log")

    static func appendToFile(_ line: String) {
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension OsmoCamera: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if case .bluetoothOff = state { state = .idle }
                if case .notAllowed = state { state = .idle }
                reconnect()
            case .unauthorized: state = .notAllowed
            default: reset(); state = .bluetoothOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        let local = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        MainActor.assumeIsolated {
            let n = local ?? p.name ?? ""
            if trace, !n.isEmpty, peripherals[p.identifier] == nil, !seenNames.contains(n) {
                seenNames.insert(n)
                note("Saw \(n) (rssi \(rssi), services \(services.map(\.uuidString)))")
            }
            let looksDJI = n.localizedCaseInsensitiveContains("osmo") || n.localizedCaseInsensitiveContains("pocket")
                || n.localizedCaseInsensitiveContains("dji") || services.contains(Self.service)
            guard looksDJI else { return }
            peripherals[p.identifier] = p
            if !found.contains(where: { $0.id == p.identifier }) {
                found.append(Found(id: p.identifier, name: n.isEmpty ? "DJI device" : n, rssi: rssi.intValue))
                note("Found \(n.isEmpty ? p.identifier.uuidString : n)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            note("Bluetooth link up; reading services")
            p.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { fail("Couldn't connect: \(error?.localizedDescription ?? "unknown error")") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let again = wantConnection
            reset()
            state = .idle
            note("Camera disconnected")
            if again {
                // Camera slept or walked out of range: wait for it to come back.
                peripheral = p
                p.delegate = self
                state = .connecting(p.name ?? "camera")
                central.connect(p)
            }
        }
    }
}

extension OsmoCamera: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
                fail("This device doesn't offer the DJI remote service (FFF0)")
                return
            }
            p.discoverCharacteristics([Self.notifyChar, Self.writeChar], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let chars = s.characteristics ?? []
            guard let w = chars.first(where: { $0.uuid == Self.writeChar }),
                  chars.contains(where: { $0.uuid == Self.notifyChar }) else {
                fail("The camera's remote service is missing FFF4/FFF5")
                return
            }
            writeTarget = w
            notifyTarget = chars.first(where: { $0.uuid == Self.notifyChar })
            let notifiable = chars.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            pendingNotify = notifiable.count
            for c in notifiable { p.setNotifyValue(true, for: c) }
            if pendingNotify == 0 { useDUML ? armDUMLPairing() : beginHandshake() }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { note("Notify on \(c.uuid) failed: \(error.localizedDescription)") }
            pendingNotify -= 1
            if pendingNotify == 0 { useDUML ? armDUMLPairing() : beginHandshake() }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard useDUML, c.uuid == Self.notifyChar else { return }
            if let error { note("Arming pairing failed: \(error.localizedDescription)") }
            beginDUMLHandshake()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let bytes = c.value.map { [UInt8]($0) } ?? []
        MainActor.assumeIsolated {
            if useDUML {
                var asm = dumlAssemblers[c.uuid] ?? DUMLFrameAssembler()
                let frames = asm.append(bytes)
                dumlAssemblers[c.uuid] = asm
                for raw in frames {
                    if let f = DUML.parse(raw) { handleDUML(f) } else if trace { note("RX bad DUML frame: " + Self.hex(raw)) }
                }
                return
            }
            // Each characteristic is its own byte stream; keep their fragments apart.
            var asm = assemblers[c.uuid] ?? RSDKFrameAssembler()
            let frames = asm.append(bytes)
            assemblers[c.uuid] = asm
            for raw in frames {
                if trace { note("RX \(c.uuid): " + Self.hex(raw)) }
                if let f = RSDK.parse(raw) { handle(f) } else if trace { note("RX frame failed to parse") }
            }
        }
    }
}
