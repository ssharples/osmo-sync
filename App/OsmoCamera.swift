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
    /// Set while something else owns the camera's Wi-Fi (the hotspot copy), so the watchdog
    /// doesn't pull the camera back onto the home network mid-copy.
    var holdWiFi = false
    private var watchdog = WiFiWatchdog()
    private var watchdogTimer: Timer?

    // Auto-connect: keeps a Bluetooth connection pending so the camera links up as soon as it
    // powers on, and acts at once on a nudge (USB plug-in, Mac wake).
    private var autoConnect = AutoConnect()
    private var autoTimer: Timer?
    /// You pressed Disconnect; only a nudge reconnects after that.
    private var userStopped = false
    private var connectingSince: Date?
    /// While set, the next Pocket a scan finds is connected to (first-time setup by nudge).
    private var autoPick = false
    /// Called when the camera shows the approval prompt and needs a tap.
    var onNeedsApproval: (() -> Void)?

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
    /// The latest `0x02/0x80` status the camera pushed over Wi-Fi.
    private var wifiCamStatus: DUMLCameraStatus?
    private var wifiCamStatusAt = Date.distantPast
    /// Raw `0x00/0x27` media-list pushes, gathered while listing.
    private var mediaChunks: [[UInt8]] = []

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
        autoTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutoConnect(nudged: false) }
        }
    }

    /// Something suggests the camera is on and close (plugged in, Mac woke, seen nearby):
    /// connect over Bluetooth now, then put it on the home Wi-Fi.
    func nudge(_ reason: String) {
        note("\(reason): bringing the Pocket online")
        userStopped = false
        runAutoConnect(nudged: true)
    }

    private func runAutoConnect(nudged: Bool) {
        guard central.state == .poweredOn else { return }
        let link: AutoConnect.Link = switch state {
        case .ready: .ready
        case .waitingForApproval: .approving
        case .connecting, .scanning: .connecting(since: connectingSince ?? Date())
        case .failed: .failed
        default: .off
        }
        let action = autoConnect.next(link: link, wifiHealthy: wifiReady, wifiSetUp: wifiCredentials?() != nil,
                                      nudged: nudged, userStopped: userStopped, now: Date())
        switch action {
        case .none: break
        case .connect: connectSavedOrFind()
        case .restart:
            note("Bluetooth connection stuck; starting again")
            wantConnection = false
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            reset()
            state = .idle
            connectSavedOrFind()
        case .rejoinWiFi:
            Task { await reconnectWiFi(reason: "Camera not on Wi-Fi") }
        }
    }

    /// Leaves a connection pending to the saved camera (it completes when the camera powers
    /// on), or, with none saved, looks for a Pocket and connects to the first one found.
    private func connectSavedOrFind() {
        if let id = savedCameraID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            wantConnection = true
            open(p)
        } else if state != .scanning {
            autoPick = true
            scan()
        }
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
        userStopped = false
        autoPick = false
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
        userStopped = true
        autoPick = false
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
        connectingSince = Date()
        central.connect(p)
        note("Connecting to \(p.name ?? p.identifier.uuidString)")
    }

    private func reset() {
        approvalTimer?.invalidate(); approvalTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        keepaliveTimer?.invalidate(); keepaliveTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        watchdog.reset()
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
            // 07/47 carries the Wi-Fi password, so never write its bytes to the log.
            let shown = f.cmdSet == 0x07 && f.cmdID == 0x47 ? "(Wi-Fi details hidden)" : Self.hex(bytes)
            note(String(format: "TX %02X/%02X flags %02X seq %04X: ", f.cmdSet, f.cmdID, f.flags, f.seq) + shown)
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
        busyRetries = 0
        approvalTimer?.invalidate(); approvalTimer = nil
        if let p = peripheral { pairedCameras.insert(p.identifier.uuidString) }
        state = .ready(name)
        note("Connected to \(name)")
        // During a copy the camera is meant to be on its own hotspot; the copy puts it back.
        if !wifiLinkOpen, !holdWiFi, let creds = wifiCredentials?() {
            Task { await joinWiFi(ssid: creds.ssid, password: creds.password) }
        }
        watchdog.reset()
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchWiFi() }
        }
    }

    // MARK: Resting between takes

    /// True while OsmoSync has closed its Wi-Fi link so the camera can idle. The camera stays
    /// on your Wi-Fi; the link reopens (about a second) when a recording starts.
    @Published private(set) var resting = false
    /// The menu is showing, so Aim may be used any moment: stay awake.
    var menuOpen = false { didSet { if menuOpen { touch("menu opened") } } }
    private var lastActivity = Date()
    private var restCheckAt = Date.distantPast
    private var restMisses = 0
    private let rest = CameraRest()

    /// Reachable over Wi-Fi, or resting with the link closed on purpose.
    var wifiReady: Bool { resting || wifiLinkHealthy }

    /// Marks activity, and reopens the link if resting.
    func touch(_ why: String) {
        lastActivity = Date()
        if resting { Task { await wake(why) } }
    }

    @discardableResult
    func wake(_ why: String) async -> Bool {
        lastActivity = Date()
        guard resting, !reconnecting, !wifiBusy else { return wifiLinkOpen }
        let started = Date()
        let ok = await findOnNetwork(within: 6)
        resting = false
        note(String(format: "Awake (%@): Wi-Fi link %@ in %.1fs", why, ok ? "open" : "didn't open", Date().timeIntervalSince(started)))
        if !ok { watchdog.reset() }  // the watchdog takes it from here
        return ok
    }

    /// Test hook only.
    func markRestingForTest() { resting = true }

    private func startResting() {
        datalink?.close(); datalink = nil
        resting = true
        restMisses = 0
        restCheckAt = Date()
        note("Resting: Wi-Fi link closed so the camera can idle. It reopens when a recording starts.")
    }

    /// While resting: one quick check a minute that the camera is still on the network.
    private func checkWhileResting() {
        guard rest.checkDue(now: Date(), lastCheck: restCheckAt) else { return }
        restCheckAt = Date()
        guard let host = lastHost else { Task { await wake("no address to check") }; return }
        Task {
            if await OsmoLANScan.probe(host) {
                restMisses = 0
            } else {
                restMisses += 1
                if rest.shouldWake(misses: restMisses) { await wake("camera stopped answering") }
            }
        }
    }

    /// The Wi-Fi link counts as alive while it's open and the camera spoke recently.
    var wifiLinkHealthy: Bool {
        guard let link = datalink, link.isOpen else { return false }
        return Date().timeIntervalSince(link.lastHeard) < 20
    }

    /// Runs every few seconds while Bluetooth is up. If the camera has dropped off the home
    /// Wi-Fi (power-off, sleep, a router blip), it puts it back without anyone pressing a button.
    private func watchWiFi() {
        guard useDUML, wifiCredentials?() != nil else { return }
        if resting {
            if holdWiFi || wifiBusy || menuOpen { Task { await wake("needed") } } else { checkWhileResting() }
            return
        }
        let busy = holdWiFi || wifiBusy || reconnecting || isRecording || dumlRecording || menuOpen
            || trackingSubject || findingSubject || stickTimer != nil
        if busy { lastActivity = Date() }
        if state.isReady, rest.shouldRest(now: Date(), lastActivity: lastActivity, busy: busy, linkHealthy: wifiLinkHealthy) {
            startResting()
            return
        }
        let action = watchdog.check(now: Date(), bleReady: state.isReady, linkHealthy: wifiLinkHealthy,
                                    held: holdWiFi || wifiBusy || reconnecting)
        if action == .rejoin { Task { await reconnectWiFi(reason: "Wi-Fi link down for a while") } }
    }

    private var reconnecting = false

    /// Reopens the Wi-Fi link, and if the camera isn't on the network, sends the join again over
    /// Bluetooth. Safe to call any time; it does nothing while a join or copy is running.
    @discardableResult
    func reconnectWiFi(reason: String) async -> Bool {
        guard useDUML, state.isReady, !holdWiFi, !wifiBusy, !reconnecting,
              let creds = wifiCredentials?() else { return wifiLinkHealthy }
        reconnecting = true
        defer { reconnecting = false }
        note("\(reason); reconnecting the camera to \(creds.ssid)")
        datalink?.close(); datalink = nil
        if await findOnNetwork(within: 3) { watchdog.reset(); return true }
        // Don't send the full join while recording: it switches the camera to video mode first.
        guard !dumlRecording else { return false }
        let ok = await joinWiFi(ssid: creds.ssid, password: creds.password)
        if ok { watchdog.reset() }
        return ok
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
            case .needsApproval:
                note("Waiting for you to approve on the camera")
                onNeedsApproval?()
            case .deferred: retryBusyPairing()
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
        lastActivity = Date()
        if !wifiLinkOpen || Date().timeIntervalSince(datalink?.lastHeard ?? .distantPast) > 5 {
            let wasResting = resting
            let t = Date()
            datalink?.close(); datalink = nil
            if wifiIdentity != nil { _ = await findOnNetwork(within: 8) }
            note(String(format: "Wi-Fi link %@ %.1fs before the record command%@", wifiLinkOpen ? "reopened" : "not open",
                        Date().timeIntervalSince(t), wasResting ? " (was resting)" : ""))
        }
        guard let link = datalink, link.isOpen else {
            note("Can't \(start ? "start" : "stop") recording: the camera isn't on Wi-Fi")
            return false
        }
        if let st = freshStatus(), st.inPlayback {
            note("The camera is showing playback; it won't record until you leave it")
        }
        note(start ? "Sent: start recording (Wi-Fi)" : "Sent: stop recording (Wi-Fi)")
        let reply = await link.request(DUML.record(start: start, seq: 0), timeout: 5)
        let code = reply?.payload.first
        if let code { note(String(format: "Record reply code %02X", code)) }
        // The reply code is ambiguous (0xDF answers both "already recording" and some refusals),
        // so trust the camera's own status push when it sends one.
        var ok: Bool
        if let seen = await waitForRecording(start, within: 4) {
            ok = seen == start
        } else {
            ok = code == 0
            note("No status from the camera; going by the reply code")
        }
        if !ok, let code { note(String(format: "Camera refused record command (code %02X)", code)) }
        if ok {
            dumlRecording = start
            onRecordingChanged?(start)
        }
        note(ok ? (start ? "Camera is recording" : "Camera stopped") : reply == nil ? "Camera did not confirm" : "Camera refused")
        return ok
    }

    /// Probe only: enter playback, check for the HTTP file server, list both stores, leave.
    func probeMedia() async {
        guard let link = datalink, link.isOpen else { note("PROBE media: no Wi-Fi link"); return }
        let host = link.host
        func list(_ counter: UInt8, _ cursor: UInt32, _ label: String) async {
            mediaChunks = []
            let r = await link.request(DUML.mediaList(counter: counter, cursor: cursor, seq: 0), timeout: 2)
            note("PROBE media: list \(label) reply \(r.map { Self.hex($0.payload) } ?? "none")")
            await pause(1.5)
            link.send(DUML.mediaListTrigger(seq: 0))
            await pause(2)
            let data = mediaChunks.filter { $0.count > 10 && $0[1] == 0x01 }.flatMap { $0.dropFirst(10) }
            note("PROBE media: \(label): \(mediaChunks.count) chunks, \(data.count) data bytes")
            let text = String(decoding: data.map { (0x20...0x7E).contains($0) ? $0 : 0x0A }, as: UTF8.self)
            for p in text.split(separator: "\n").filter({ $0.count > 8 && $0.contains("/") }).prefix(8) {
                note("PROBE media path: \(p)")
            }
            for c in mediaChunks.prefix(4) { note("PROBE media chunk: " + Self.hex(Array(c.prefix(48)))) }
        }
        await list(1, 1, "SD before playback")
        await list(2, 0x4000_0001, "internal before playback")
        for attempt in 1...3 {
            let r = await link.request(DUML.playback(true, seq: 0), timeout: 1)
            note("PROBE media: enter playback #\(attempt) reply \(r.map { Self.hex($0.payload) } ?? "none")")
            await pause(1.2)
            if freshStatus()?.inPlayback == true { break }
        }
        note("PROBE media: in playback \(freshStatus()?.inPlayback.description ?? "?")")
        await pause(1.7)
        for port: UInt16 in [80, 21, 8080] {
            note("PROBE media: port \(port) open \(await OsmoLANScan.probe(host, port: port))")
        }
        await list(1, 1, "SD in playback")
        await list(2, 0x4000_0001, "internal in playback")
        let r2 = await link.request(DUML.playback(false, seq: 0), timeout: 3)
        note("PROBE media: leave playback reply \(r2.map { Self.hex($0.payload) } ?? "none")")
    }

    // MARK: Hotspot copy

    /// Lists clips over the Wi-Fi link: internal storage, then the microSD card if any.
    /// Returns paths without extension, newest first, each with the `/v2` storage id to try first.
    /// A clip on the camera. `handle` and `size` come from the media list; zero if it didn't say.
    struct CameraClip: Equatable {
        var path: String
        var storage: Int
        var handle: UInt32 = 0
        var size: UInt32 = 0
    }

    /// The stores (1 internal, 0 card) whose list finished with an end-of-list chunk in the last
    /// `listClips()`. Only a finished list proves a clip is missing from it. An empty card slot
    /// sends a short "nothing here" chunk instead, and counts as not answered.
    private(set) var lastListAnswered: Set<Int> = []

    func listClips() async -> [CameraClip] {
        guard let link = datalink, link.isOpen else { lastListAnswered = []; return [] }
        var out: [CameraClip] = []
        var answered: Set<Int> = []
        for (counter, cursor, storage) in [(UInt8(2), UInt32(0x4000_0001), 1), (UInt8(1), UInt32(1), 0)] {
            mediaChunks = []
            let reply = await link.request(DUML.mediaList(counter: counter, cursor: cursor, seq: 0), timeout: 2)
            await pause(1)
            link.send(DUML.mediaListTrigger(seq: 0))
            // Wait for the end-of-list chunk (subtype 03), up to four seconds.
            for _ in 0..<20 where !mediaChunks.contains(where: { $0.count > 1 && $0[1] == 0x03 }) { await pause(0.2) }
            if mediaChunks.contains(where: { $0.count > 1 && $0[1] == 0x03 }) { answered.insert(storage) }
            let data = Array(mediaChunks.filter { $0.count > 10 && $0[1] == 0x01 }.flatMap { $0.dropFirst(10) })
            let paths = OsmoClips.paths(in: data)
            let records = Dictionary(OsmoMedia.records(in: data).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            if paths.isEmpty {
                note("Clip list reply \(reply.map { Self.hex($0.payload) } ?? "none"), \(mediaChunks.count) chunks: "
                     + mediaChunks.prefix(3).map { Self.hex(Array($0.prefix(24))) }.joined(separator: " | "))
            }
            note("Clip list (\(storage == 1 ? "internal" : "card")): \(paths.count) clip\(paths.count == 1 ? "" : "s")")
            out += paths.map { CameraClip(path: $0, storage: storage, handle: records[$0]?.handle ?? 0, size: records[$0]?.size ?? 0) }
        }
        lastListAnswered = answered
        return out
    }

    enum DeleteOutcome: Equatable {
        case deleted
        case kept(String)
        /// The camera may or may not have deleted it; the re-list couldn't tell.
        case unsure(String)
    }

    /// Deletes one clip from the camera, by the handle the camera lists for it right now.
    /// Refuses unless the camera is idle and still lists `path` at `size` bytes (low 32 bits).
    /// Never re-sends: the camera reuses file numbers, so a stale handle could hit another file.
    func deleteClip(path: String, storage: Int, size: Int64) async -> DeleteOutcome {
        guard !isRecording, freshStatus()?.isRecording != true else { return .kept("the camera is recording") }
        // A long-open link stops answering some commands, so start a fresh one.
        disconnectWiFi()
        guard await findOnNetwork(within: 20), let link = datalink else { return .kept("the camera isn't on Wi-Fi") }
        let before = await listClips()
        guard lastListAnswered.contains(storage) else { return .kept("the camera didn't send its clip list") }
        guard let clip = before.first(where: { $0.path == path && $0.storage == storage }) else {
            return .kept("the camera no longer lists it")
        }
        guard clip.handle != 0 else { return .kept("the camera's list gave no file id") }
        guard clip.size == UInt32(truncatingIfNeeded: size) else {
            return .kept("the camera lists \(clip.size) bytes, the copy has \(size)")
        }
        guard Set(before.map(\.handle)).count == before.count else { return .kept("two clips share a file id") }

        // The camera only answers deletes in playback; leave playback afterwards or it won't record.
        _ = await link.request(DUML.playback(true, seq: 0), timeout: 2)
        await pause(1.5)
        note(String(format: "Deleting %@ (handle %08X, %lld bytes) from the camera", path, clip.handle, size))
        let reply = await link.request(DUML.deleteFiles(handles: [clip.handle], seq: 0), timeout: 10, skipEmpty: true)
        let status = reply.flatMap { DUML.deleteStatus($0.payload) }
        note("Delete reply: \(status.map { String(format: "%04X", $0) } ?? "none")")
        link.send(DUML.playback(false, seq: 0))
        await pause(1.5)

        let after = await listClips()
        guard lastListAnswered.contains(storage) else { return .unsure("the camera didn't send its list after the delete") }
        let others = Set(before.filter { $0.storage == storage }.map(\.path)).subtracting([path])
        let lost = others.subtracting(after.map(\.path))
        if !lost.isEmpty { note("WARNING: other clips also gone from the camera: \(lost.sorted().joined(separator: ", "))") }
        if after.contains(where: { $0.path == path && $0.storage == storage }) {
            return .kept("the camera still lists it (reply \(status.map { String(format: "%04X", $0) } ?? "none"))")
        }
        return .deleted
    }

    /// The camera's own hotspot name and password, read over Bluetooth. Never logged.
    func hotspotLogin() async -> (ssid: String, password: String)? {
        guard useDUML, state.isReady else { return nil }
        guard let n = await bleRequest(DUML.getWiFiName(seq: nextDUMLSeq()), timeout: 8)?.payload,
              let ssid = OsmoClips.packedString(n) else { note("Camera didn't give its hotspot name"); return nil }
        await pause(0.5)
        guard let p = await bleRequest(DUML.getWiFiPassword(seq: nextDUMLSeq()), timeout: 8)?.payload,
              let password = OsmoClips.packedString(p) else { note("Camera didn't give its hotspot password"); return nil }
        note("Camera hotspot: \(ssid)")
        return (ssid, password)
    }

    /// Takes the camera off your Wi-Fi and back onto its own hotspot, where it serves files.
    func switchToHotspot() async -> Bool {
        guard useDUML, state.isReady else { return false }
        disconnectWiFi()
        let r = await bleRequest(DUML.stationMode(false, seq: nextDUMLSeq()), timeout: 12)?.payload
        note("Hotspot switch reply: \(r.map { Self.hex($0) } ?? "none")")
        for _ in 0..<10 {
            await pause(1)
            let role = await bleRequest(DUML.wifiRole(seq: nextDUMLSeq()), timeout: 6)?.payload ?? []
            // `00 FF` means the radio is off (a hotspot that shut down), not a hotspot.
            if DUMLStation.role(role) == .accessPoint { note("Camera is on its own hotspot (\(Self.hex(role)))"); return true }
            if !role.isEmpty { note("Camera Wi-Fi role while switching: \(Self.hex(role))") }
        }
        // The readback isn't always clear; the Mac's join decides.
        note("Camera hotspot role unconfirmed; trying to join anyway")
        return r != nil
    }

    /// Brings a hotspot that shut down back up: back to station mode, then hotspot again.
    /// Sending "hotspot" alone to a camera whose hotspot died leaves its radio off (`00 FF`).
    func restartHotspot() async -> Bool {
        guard useDUML, state.isReady else { return false }
        let r = await bleRequest(DUML.stationMode(true, seq: nextDUMLSeq()), timeout: 12)?.payload
        note("Hotspot restart, station switch reply: \(r.map { Self.hex($0) } ?? "none")")
        for _ in 0..<10 {
            await pause(1)
            let role = await bleRequest(DUML.wifiRole(seq: nextDUMLSeq()), timeout: 6)?.payload ?? []
            if DUMLStation.role(role) == .station { break }
        }
        await pause(2)
        return await switchToHotspot()
    }

    private func freshStatus() -> DUMLCameraStatus? {
        Date().timeIntervalSince(wifiCamStatusAt) < 3 ? wifiCamStatus : nil
    }

    /// Waits for the status push to show `want`. Returns the last state seen, or nil if none came.
    private func waitForRecording(_ want: Bool, within s: Double) async -> Bool? {
        let deadline = Date().addingTimeInterval(s)
        while Date() < deadline {
            if let st = freshStatus(), st.isRecording == want { return want }
            await pause(0.2)
        }
        return freshStatus()?.isRecording
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
        if role != .accessPoint {
            // Already on a network, or a reply we haven't seen (a Pocket 4P after a firmware
            // update answered 00 08). Look on the LAN first.
            wifiStatus = "Looking for the camera on \(ssid)"
            if await findOnNetwork(within: role == .station ? 15 : 5) { return true }
        }
        if role != .station {
            wifiStatus = "Switching camera to your Wi-Fi"
            let sw = await bleRequest(DUML.stationMode(true, seq: nextDUMLSeq()), timeout: 12)?.payload
            note("Station switch reply: \(sw.map { Self.hex($0) } ?? "none")")
            guard sw == [0, 0] || sw == [0] else {
                wifiStatus = "Camera refused to join a network (\(Self.hex(sw ?? [])))"
                note(wifiStatus)
                return false
            }
            var switched = false
            for _ in 0..<6 {
                let r = await bleRequest(DUML.wifiRole(seq: nextDUMLSeq()), timeout: 12)?.payload ?? []
                note("Camera Wi-Fi role: \(Self.hex(r))")
                if DUMLStation.role(r) == .station { switched = true; break }
                if DUMLStation.role(r) == .unknown, r != roleReply { break }  // changed to something new
                await pause(2)
            }
            // An unrecognised readback isn't proof of failure; the join reply and the
            // identity check on the LAN decide.
            if !switched, roleReply == [0, 0] {
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
                wifiCamStatus = nil
                link.onPush = { [weak self] f in
                    guard let self else { return }
                    if f.cmdSet == 0x00, f.cmdID == 0x27 { self.mediaChunks.append(f.payload); return }
                    guard let st = DUMLCameraStatus(f) else { return }
                    if self.trace, st.isRecording != self.wifiCamStatus?.isRecording || st.inPlayback != self.wifiCamStatus?.inPlayback {
                        self.note("Camera status: recording \(st.isRecording), playback \(st.inPlayback)")
                    }
                    if st.hot != (self.wifiCamStatus?.hot ?? false) {
                        self.note(String(format: "Camera heat flag %@ (status flags %08X)", st.hot ? "ON" : "off", st.flags))
                    }
                    self.wifiCamStatus = st
                    self.wifiCamStatusAt = Date()
                }
                lastHost = host
                resting = false
                lastActivity = Date()
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

    // MARK: Pan, tilt and zoom (over the Wi-Fi link)

    private var stick = (pan: 0.0, tilt: 0.0)
    private var stickTimer: Timer?
    private var stickLogged = false
    @Published private(set) var zoomFactor = 1.0

    var canControl: Bool { datalink?.isOpen == true }

    /// Sets the joystick: −1…1 on each axis, the speed to turn at. Zero on both stops.
    /// Frames stream every 40 ms while it's off centre, as DJI's own app does.
    func steer(pan: Double, tilt: Double) {
        stick = (pan, tilt)
        let moving = GimbalStick.axis(pan) != GimbalStick.centre || GimbalStick.axis(tilt) != GimbalStick.centre
        guard let link = datalink, link.isOpen else {
            if moving, !stickLogged { note("Can't move the gimbal: the camera isn't on Wi-Fi"); stickLogged = true }
            return
        }
        if moving {
            if !stickLogged { note(String(format: "Gimbal stick: pan %.2f, tilt %.2f", pan, tilt)); stickLogged = true }
            guard stickTimer == nil else { return }
            link.send(DUML.gimbalStick(tilt: tilt, pan: pan, seq: 0))
            stickTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let link = self.datalink, link.isOpen else { return }
                    link.send(DUML.gimbalStick(tilt: self.stick.tilt, pan: self.stick.pan, seq: 0))
                }
            }
        } else {
            stickTimer?.invalidate(); stickTimer = nil
            stickLogged = false
            // Two rest frames, in case the first is lost.
            link.send(DUML.gimbalStick(tilt: 0, pan: 0, seq: 0))
            link.send(DUML.gimbalStick(tilt: 0, pan: 0, seq: 0))
        }
    }

    func recentreGimbal() {
        guard let link = datalink, link.isOpen else { note("Can't recentre: the camera isn't on Wi-Fi"); return }
        Task {
            let r = await link.request(DUML.gimbalRecentre(seq: 0), timeout: 2)
            note("Recentre gimbal: " + (r.map { Self.hex($0.payload) } ?? "no reply"))
        }
    }

    func setZoom(_ factor: Double) {
        let f = (min(max(factor, Zoom.range.lowerBound), Zoom.range.upperBound) * 10).rounded() / 10
        zoomFactor = f
        guard let link = datalink, link.isOpen else { note("Can't zoom: the camera isn't on Wi-Fi"); return }
        Task {
            let r = await link.request(DUML.zoom(factor: f, seq: 0), timeout: 2)
            note(String(format: "Zoom %.1f×: ", f) + (r.map { Self.hex($0.payload) } ?? "no reply"))
        }
    }

    @Published private(set) var findingSubject = false
    @Published private(set) var trackingSubject = false
    private var trackID: UInt16 = 1

    /// "Find me": point the gimbal ahead, ask the camera to track whoever is in the middle of
    /// the frame (its own ActiveTrack keeps them framed from then on), then focus on them.
    /// The Mac has no picture from the camera, so this assumes you sit roughly in front of it.
    func findSubject() {
        guard let link = datalink, link.isOpen else { note("Can't find you: the camera isn't on Wi-Fi"); return }
        guard !findingSubject else { return }
        findingSubject = true
        Task {
            defer { findingSubject = false }
            steer(pan: 0, tilt: 0)
            _ = await link.request(DUML.stopTracking(seq: 0), timeout: 1)
            let r = await link.request(DUML.gimbalRecentre(seq: 0), timeout: 2)
            note("Find me: recentre " + (r.map { Self.hex($0.payload) } ?? "no reply"))
            await pause(1.5)
            // A head-and-shoulders box in the middle, a little above centre.
            let id = trackID; trackID = trackID &+ 1 == 0 ? 1 : trackID &+ 1
            let t = await link.request(DUML.trackSubject(id: id, centreX: 0.5, centreY: 0.42, width: 0.3, height: 0.45,
                                                         seq: 0), timeout: 2)
            note("Find me: track " + (t.map { Self.hex($0.payload) } ?? "no reply"))
            var locked = false
            for _ in 0..<10 {
                await pause(0.4)
                if let p = await link.request(DUML.trackingState(seq: 0), timeout: 1)?.payload, DUML.isTrackingLocked(p) {
                    locked = true; break
                }
            }
            trackingSubject = locked
            for f in DUML.focus(x: 0.5, y: 0.42, seq: 0) {
                let a = await link.request(f, timeout: 1)
                if a?.payload.first != 0 { note(String(format: "Find me: focus %02X ", f.cmdID) + (a.map { Self.hex($0.payload) } ?? "no reply")) }
            }
            note(locked ? "Find me: tracking you and focused" : "Find me: focused, but the camera didn't lock on to anyone")
        }
    }

    func stopTracking() {
        trackingSubject = false
        guard let link = datalink, link.isOpen else { return }
        Task {
            let r = await link.request(DUML.stopTracking(seq: 0), timeout: 2)
            note("Stop tracking: " + (r.map { Self.hex($0.payload) } ?? "no reply"))
        }
    }

    private var busyRetries = 0

    /// The camera answers "busy" for a few seconds after waking or after another app let go.
    /// Drop the link and try again, up to five times, before giving up.
    private func retryBusyPairing() {
        busyRetries += 1
        guard busyRetries <= 5, let id = peripheral?.identifier ?? savedCameraID else {
            busyRetries = 0
            fail("The camera is busy pairing. Try again in a few seconds.")
            return
        }
        note("Camera busy pairing; retrying in 4s (\(busyRetries)/5)")
        wantConnection = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        reset()
        state = .connecting("camera")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.peripheral == nil else { return }
            self.connect(to: id)
        }
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
            if autoPick, Self.speaksDUML(n) {
                autoPick = false
                connect(to: p.identifier)
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
                connectingSince = Date()
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
