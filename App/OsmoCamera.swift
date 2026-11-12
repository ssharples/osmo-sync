import CoreBluetooth
import Foundation
import OsmoSyncCore
import os

private let logger = Logger(subsystem: "com.ssharples.OsmoSync", category: "app")

/// Talks to an Osmo camera over Bluetooth using DJI's R-SDK remote protocol:
/// pair once (approve on the camera's screen), then start and stop recording.
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

    private var pairedCameras: Set<String> {
        get { Set(defaults.stringArray(forKey: "pairedCameras") ?? []) }
        set { defaults.set(Array(newValue), forKey: "pairedCameras") }
    }

    var hasSavedCamera: Bool { savedCameraID != nil }
    var isRecording: Bool { status?.isRecording ?? false }

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
    func startRecording() async -> Bool { await sendRecord(start: true) }

    /// Stops recording. Returns true when the camera confirms.
    @discardableResult
    func stopRecording() async -> Bool { await sendRecord(start: false) }

    // MARK: Internals

    private func open(_ p: CBPeripheral) {
        reset()
        peripheral = p
        p.delegate = self
        state = .connecting(p.name ?? "camera")
        central.connect(p)
        note("Connecting to \(p.name ?? p.identifier.uuidString)")
    }

    private func reset() {
        approvalTimer?.invalidate(); approvalTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        writeTarget = nil
        assemblers = [:]
        pendingNotify = 0
        status = nil
        for (_, c) in recordWaiters { c.resume(returning: false) }
        recordWaiters = [:]
        peripheral = nil
    }

    private var name: String { peripheral?.name ?? "the camera" }

    private func nextSeq() -> UInt16 { seq = seq &+ 1; if seq == 0 { seq = 1 }; return seq }

    @discardableResult
    private func send(_ set: UInt8, _ id: UInt8, type: UInt8, payload: [UInt8], seq s: UInt16? = nil) -> UInt16 {
        let useSeq = s ?? nextSeq()
        guard let p = peripheral, let c = writeTarget else { return useSeq }
        let frame = RSDK.frame(cmdSet: set, cmdID: id, cmdType: type, payload: payload, seq: useSeq)
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
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
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
            let notifiable = chars.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            pendingNotify = notifiable.count
            for c in notifiable { p.setNotifyValue(true, for: c) }
            if pendingNotify == 0 { beginHandshake() }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { note("Notify on \(c.uuid) failed: \(error.localizedDescription)") }
            pendingNotify -= 1
            if pendingNotify == 0 { beginHandshake() }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let bytes = c.value.map { [UInt8]($0) } ?? []
        MainActor.assumeIsolated {
            // Each characteristic is its own byte stream; keep their fragments apart.
            var asm = assemblers[c.uuid] ?? RSDKFrameAssembler()
            let frames = asm.append(bytes)
            assemblers[c.uuid] = asm
            for raw in frames {
                if let f = RSDK.parse(raw) { handle(f) }
            }
        }
    }
}
