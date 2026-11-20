import AVFoundation
import AppKit
import Foundation
import OsmoSyncCore
import Security
import UserNotifications

/// The home Wi-Fi password, kept in the login keychain rather than in preferences.
enum WiFiKeychain {
    private static let service = "com.ssharples.OsmoSync.wifi"

    static func password(for ssid: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: ssid, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ password: String, for ssid: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: ssid]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// One Screen Studio recording and the camera clips that go with it.
struct Take: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date?
    var cameraStarted: Bool
    var imported: [String] = []
    var importNote: String?
    /// When the camera confirmed it was recording.
    var cameraStartedAt: Date?
    /// The lined-up copy of the first clip, and what happened when making it.
    var synced: String?
    var syncNote: String?
    /// The camera files the copies came from, for deleting them afterwards. Optional so takes
    /// saved by older versions still load.
    var cameraFiles: [CameraFile]?
    /// Set once every copied clip has been removed from the camera.
    var removedFromCamera: Bool?
    /// Why a clip stayed on the camera, when it did.
    var deleteNote: String?
    /// Set when the clip came out below 4K 60 (usually because of the webcam stream).
    var qualityNote: String?

    struct CameraFile: Codable, Equatable {
        /// The copy in Osmo Takes.
        var local: String
        /// `DCIM/…` path on the camera, without extension, and which store holds it.
        var path: String
        var storage: Int
        /// Bytes the camera served, which the copy must match.
        var size: Int64
        /// Bytes and file id in the camera's media list when the copy was made.
        var listedSize: UInt32
        var handle: UInt32
    }

    var isOpen: Bool { end == nil }
    var needsImport: Bool { end != nil && cameraStarted && imported.isEmpty }
}

@MainActor
final class AppModel: ObservableObject {
    let camera = OsmoCamera()

    @Published var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "autoRecord") } }
    @Published var autoImport: Bool { didSet { defaults.set(autoImport, forKey: "autoImport") } }
    @Published var autoLineUp: Bool { didSet { defaults.set(autoLineUp, forKey: "autoLineUp") } }
    /// Delete each clip from the Pocket once its copy on the Mac is checked.
    @Published var autoDelete: Bool { didSet { defaults.set(autoDelete, forKey: "autoDelete") } }
    /// What "Clean up camera" is doing, shown in the menu. Empty when idle.
    @Published private(set) var cleanupStatus = ""
    @Published var projectsFolder: URL { didSet { defaults.set(projectsFolder.path, forKey: "projectsFolder"); restartWatcher() } }
    @Published var destination: URL { didSet { defaults.set(destination.path, forKey: "destination") } }
    @Published private(set) var takes: [Take] = []
    @Published private(set) var screenStudioRecording = false
    @Published private(set) var importing = false
    /// What the Wi-Fi hotspot copy is doing, shown in the menu. Empty when idle.
    @Published private(set) var hotspotStatus = ""
    /// The take a Wi-Fi copy is working on, and its progress line for that take's row.
    @Published private(set) var copyingTake: UUID?
    @Published private(set) var copyProgress = ""
    /// Test hook only: turn the Mac's Wi-Fi off briefly once a copy passes this percentage.
    private var dropWiFiAt: Int?
    /// Home Wi-Fi the camera joins so the Mac can start and stop it. Password lives in the keychain.
    @Published var wifiSSID: String {
        didSet { defaults.set(wifiSSID, forKey: "wifiSSID"); if oldValue != wifiSSID { wifiPassword = nil } }
    }

    private let defaults = UserDefaults.standard
    private var tailer: ScreenStudioLogTailer?
    private var startTask: Task<Bool, Never>?
    private var timer: Timer?
    private let usb = USBWatcher()
    private var lastUSBNudge = Date.distantPast
    /// Set by a nudge: say "Pocket ready" when it's up, or say what's wrong if it isn't soon.
    private var announce: (reason: String, at: Date)?
    private var readyTimer: Timer?
    private var downSince: Date? = Date()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        autoRecord = defaults.object(forKey: "autoRecord") as? Bool ?? true
        autoImport = defaults.object(forKey: "autoImport") as? Bool ?? true
        autoLineUp = defaults.object(forKey: "autoLineUp") as? Bool ?? true
        autoDelete = defaults.object(forKey: "autoDelete") as? Bool ?? true
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        projectsFolder = URL(fileURLWithPath: defaults.string(forKey: "projectsFolder")
                             ?? home.appendingPathComponent("Screen Studio Projects").path)
        destination = URL(fileURLWithPath: defaults.string(forKey: "destination")
                          ?? home.appendingPathComponent("Movies/Osmo Takes").path)
        if let data = defaults.data(forKey: "takes"), let saved = try? JSONDecoder().decode([Take].self, from: data) {
            // A take still open from last run never got its stop; close it so it can import.
            takes = saved.map { var t = $0; if t.end == nil { t.end = t.start.addingTimeInterval(1) }; return t }
        }
        restartWatcher()
        camera.wifiCredentials = { [weak self] in
            guard let self, !self.wifiSSID.isEmpty, let pw = self.wifiPassword else { return nil }
            return (self.wifiSSID, pw)
        }
        loadWiFiPassword()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.volumeMounted(url) }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        startAutoConnect()
        if CommandLine.arguments.contains("--probe") { runProbe() }
        if CommandLine.arguments.contains("--line-up") {
            // Test hook: line up every copied take that hasn't been lined up yet.
            Task { @MainActor in
                for take in takes where !take.imported.isEmpty && take.synced == nil { await lineUp(take) }
                camera.note("LINE-UP TEST: done")
            }
        }
        if CommandLine.arguments.contains("--drop-wifi") {
            // Test hook: knock the camera off the home Wi-Fi (as a power cycle does) and check
            // the watchdog puts it back with nobody pressing anything.
            Task { @MainActor in
                for _ in 0..<180 where !(camera.state.isReady && camera.wifiLinkHealthy) { try? await Task.sleep(for: .seconds(0.5)) }
                camera.note("DROP TEST: camera ready \(camera.state.isReady), Wi-Fi link \(camera.wifiLinkHealthy)")
                let off = await camera.switchToHotspot()
                camera.note("DROP TEST: camera moved to its hotspot: \(off)")
                let started = Date()
                try? await Task.sleep(for: .seconds(5))
                while !camera.wifiLinkHealthy, Date().timeIntervalSince(started) < 240 { try? await Task.sleep(for: .seconds(1)) }
                camera.note(String(format: "DROP TEST: back on Wi-Fi %@ after %.0fs", camera.wifiLinkHealthy ? "yes" : "no", Date().timeIntervalSince(started)))
            }
        }
        if CommandLine.arguments.contains("--delete-test") {
            // Test hook: record a few seconds on the camera, copy that clip over the hotspot,
            // and let the checked delete remove it. Touches no other clip.
            Task { @MainActor in
                for _ in 0..<180 where !(camera.state.isReady && camera.wifiLinkOpen) { try? await Task.sleep(for: .seconds(0.5)) }
                guard camera.state.isReady, camera.wifiLinkOpen else { camera.note("DELETE TEST: camera not ready"); return }
                guard !screenStudioRecording, !camera.isRecording else { camera.note("DELETE TEST: a recording is running; not testing"); return }
                // Retry earlier test clips that stayed on the camera before making a new one.
                let earlier = takes.filter { $0.name.hasPrefix("OsmoSync delete test") && $0.removedFromCamera != true && $0.cameraFiles?.isEmpty == false }
                if !earlier.isEmpty {
                    camera.holdWiFi = true
                    for t in earlier {
                        await removeFromCamera(t)
                        camera.note("DELETE TEST: retried \(t.name): \(takes.first { $0.id == t.id }?.deleteNote ?? "none")")
                    }
                    camera.holdWiFi = false
                    let now = await camera.listClips()
                    camera.note("DELETE TEST: camera lists \(now.count) clips; done")
                    return
                }
                let start = Date()
                guard await camera.startRecording() else { camera.note("DELETE TEST: camera didn't start"); return }
                let started = Date()
                try? await Task.sleep(for: .seconds(4))
                await camera.stopRecording()
                var t = Take(name: "OsmoSync delete test \(start.formatted(.iso8601.time(includingFractionalSeconds: false)))",
                             start: start, end: Date(), cameraStarted: true)
                t.cameraStartedAt = started
                addTake(t)
                try? await Task.sleep(for: .seconds(3))
                let before = await camera.listClips().map(\.path)
                camera.note("DELETE TEST: camera lists \(before.count) clips before")
                await copyOverHotspot(t)
                let after = takes.first { $0.id == t.id }
                camera.note("DELETE TEST: copied \(after?.imported ?? []), note: \(after?.deleteNote ?? "none")")
                let now = await camera.listClips().map(\.path)
                let gone = Set(before).subtracting(now)
                camera.note("DELETE TEST: camera lists \(now.count) clips after; gone: \(gone.sorted())")
                for f in after?.imported ?? [] {
                    let url = URL(fileURLWithPath: f)
                    camera.note("DELETE TEST: Mac copy \(url.lastPathComponent) \(Self.fileSize(url) ?? -1) bytes, \(await Self.videoDuration(url) ?? -1)s")
                }
                camera.note("DELETE TEST: done")
            }
        }
        if CommandLine.arguments.contains("--quality-test") {
            // Test hook: record about 8 seconds with no webcam stream, copy the clip the usual
            // way (USB if the camera is mounted, else Wi-Fi), then log its size and frame rate.
            Task { @MainActor in
                for _ in 0..<60 where !camera.state.isReady { try? await Task.sleep(for: .seconds(0.5)) }
                guard camera.state.isReady else { camera.note("QUALITY TEST: camera not connected"); return }
                guard !screenStudioRecording, !camera.isRecording else { camera.note("QUALITY TEST: a recording is running; not testing"); return }
                guard !WebcamUse.osmoInUse() else { camera.note("QUALITY TEST: the webcam is in use; not testing"); return }
                camera.note("QUALITY TEST: card mounted \(cameraCardMounted)")
                let start = Date()
                guard await camera.startRecording() else { camera.note("QUALITY TEST: camera didn't start"); return }
                let started = Date()
                try? await Task.sleep(for: .seconds(8))
                await camera.stopRecording()
                var t = Take(name: "OsmoSync quality test \(start.formatted(.iso8601.time(includingFractionalSeconds: false)))",
                             start: start, end: Date(), cameraStarted: true)
                t.cameraStartedAt = started
                addTake(t)
                try? await Task.sleep(for: .seconds(3))
                if cameraCardMounted {
                    importPending()
                    for _ in 0..<120 where takes.first(where: { $0.id == t.id })?.imported.isEmpty ?? true {
                        try? await Task.sleep(for: .seconds(1))
                    }
                } else {
                    await copyOverHotspot(t)
                }
                for f in takes.first(where: { $0.id == t.id })?.imported ?? [] {
                    let q = await Self.clipQuality(URL(fileURLWithPath: f))
                    camera.note("QUALITY TEST: \(URL(fileURLWithPath: f).lastPathComponent): \(q?.summary ?? "unreadable")")
                }
                camera.note("QUALITY TEST: done")
            }
        }
        if CommandLine.arguments.contains("--rest-test") {
            // Test hook: wait for the camera to rest, let one network check pass, then time how
            // long the Wi-Fi link takes to come back (what a recording start would wait for).
            Task { @MainActor in
                for _ in 0..<600 where !camera.resting { try? await Task.sleep(for: .seconds(1)) }
                guard camera.resting else { camera.note("REST TEST: never rested"); return }
                try? await Task.sleep(for: .seconds(75))
                camera.note("REST TEST: still resting \(camera.resting); waking")
                for i in 1...3 {
                    let t = Date()
                    let ok = await camera.wake("rest test \(i)")
                    camera.note(String(format: "REST TEST: wake %d %@ in %.2fs", i, ok ? "ok" : "failed", Date().timeIntervalSince(t)))
                    if i < 3 {
                        camera.disconnectWiFi()
                        camera.markRestingForTest()
                    }
                }
                camera.note("REST TEST: done")
            }
        }
        if CommandLine.arguments.contains("--big-copy-test") {
            // Test hook: record a clip over 2 GB, copy it over the hotspot, and turn the Mac's
            // Wi-Fi off for a few seconds partway through so the copy has to rejoin and resume.
            // Stops the camera at once if Screen Studio starts. Touches no other clip.
            Task { @MainActor in
                for _ in 0..<180 where !(camera.state.isReady && camera.wifiLinkOpen) { try? await Task.sleep(for: .seconds(0.5)) }
                guard camera.state.isReady, camera.wifiLinkOpen else { camera.note("BIG COPY TEST: camera not ready"); return }
                guard !screenStudioRecording, !camera.isRecording else { camera.note("BIG COPY TEST: a recording is running; not testing"); return }
                if let earlier = takes.first(where: { $0.name.hasPrefix("OsmoSync big copy test") && $0.imported.isEmpty }) {
                    // Reuse the test clip already on the camera rather than record another.
                    camera.note("BIG COPY TEST: copying \(earlier.name) again")
                    dropWiFiAt = 35
                    await copyOverHotspot(earlier)
                    dropWiFiAt = nil
                    let after = takes.first { $0.id == earlier.id }
                    camera.note("BIG COPY TEST: copied \(after?.imported ?? []), note: \(after?.importNote ?? "none"); \(after?.deleteNote ?? "")")
                    for f in after?.imported ?? [] {
                        let url = URL(fileURLWithPath: f)
                        camera.note("BIG COPY TEST: Mac copy \(url.lastPathComponent) \(Self.fileSize(url) ?? -1) bytes, \(await Self.videoDuration(url) ?? -1)s")
                    }
                    camera.note("BIG COPY TEST: done")
                    return
                }
                let start = Date()
                guard await camera.startRecording() else { camera.note("BIG COPY TEST: camera didn't start"); return }
                let started = Date()
                camera.note("BIG COPY TEST: recording ~4 minutes")
                while Date().timeIntervalSince(started) < 240, !screenStudioRecording { try? await Task.sleep(for: .seconds(1)) }
                await camera.stopRecording()
                guard !screenStudioRecording else { camera.note("BIG COPY TEST: Screen Studio started; stopped the test"); return }
                var t = Take(name: "OsmoSync big copy test \(start.formatted(.iso8601.time(includingFractionalSeconds: false)))",
                             start: start, end: Date(), cameraStarted: true)
                t.cameraStartedAt = started
                addTake(t)
                try? await Task.sleep(for: .seconds(3))
                dropWiFiAt = 35
                await copyOverHotspot(t)
                dropWiFiAt = nil
                let after = takes.first { $0.id == t.id }
                camera.note("BIG COPY TEST: copied \(after?.imported ?? []), note: \(after?.importNote ?? "none"); \(after?.deleteNote ?? "")")
                for f in after?.imported ?? [] {
                    let url = URL(fileURLWithPath: f)
                    camera.note("BIG COPY TEST: Mac copy \(url.lastPathComponent) \(Self.fileSize(url) ?? -1) bytes, \(await Self.videoDuration(url) ?? -1)s")
                }
                camera.note("BIG COPY TEST: done")
            }
        }
        if CommandLine.arguments.contains("--cleanup-dry-run") {
            // Test hook: report what "Clean up camera" would remove. Deletes nothing.
            Task { @MainActor in
                for _ in 0..<180 where !(camera.state.isReady && camera.wifiLinkOpen) { try? await Task.sleep(for: .seconds(0.5)) }
                camera.holdWiFi = true
                let items = await cleanupCandidates()
                camera.holdWiFi = false
                camera.note("CLEANUP DRY RUN: \(items.count) clips, \(Self.sizeText(items.reduce(0) { $0 + $1.size }))")
            }
        }
        if CommandLine.arguments.contains("--copy-latest") {
            // Test hook: wait for the camera and its Wi-Fi link, then copy the newest waiting take.
            Task { @MainActor in
                for _ in 0..<180 where !(camera.state.isReady && camera.wifiLinkOpen) { try? await Task.sleep(for: .seconds(0.5)) }
                camera.note("COPY TEST: camera ready \(camera.state.isReady), Wi-Fi link \(camera.wifiLinkOpen)")
                guard let take = takes.first(where: \.needsImport) else { camera.note("COPY TEST: nothing waiting"); return }
                if CommandLine.arguments.contains("--fail-hotspot") { camera.failNextHotspotSwitch = true }
                await copyOverHotspot(take)
                camera.note("COPY TEST: done")
            }
        }
    }

    // MARK: Auto-connect

    private func startAutoConnect() {
        usb.onPocket = { [weak self] name in self?.pocketPluggedIn(name) }
        usb.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the Mac's Wi-Fi and Bluetooth a few seconds to come back first.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                self?.nudge("Mac woke", announceIfUp: false)
            }
        }
        camera.onNeedsApproval = { [weak self] in
            self?.notify("Tap OK on the Pocket", "The Pocket is asking to pair with OsmoSync. Tap OK on its screen.")
        }
        readyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchReady() }
        }
    }

    private func pocketPluggedIn(_ name: String) {
        // Switching the Pocket's USB mode reconnects it; one nudge per plug-in is enough.
        guard Date().timeIntervalSince(lastUSBNudge) > 30 else { return }
        lastUSBNudge = Date()
        camera.note("USB: \(name) plugged in")
        nudge("Pocket plugged in", announceIfUp: true)
    }

    private func nudge(_ reason: String, announceIfUp: Bool) {
        let wasUp = pocketUp
        if !wasUp || announceIfUp { announce = (reason, Date()) }
        camera.nudge(reason)
        watchReady()
    }

    /// Bluetooth up and, when Wi-Fi is set up, the camera reachable over it.
    private var pocketUp: Bool {
        camera.state.isReady && (!hasWiFiPassword || camera.wifiReady)
    }

    private func watchReady() {
        let busy = !hotspotStatus.isEmpty || !cleanupStatus.isEmpty || camera.holdWiFi
        if pocketUp {
            // Coming back after a long gap (camera powered on nearby) counts as news too.
            if announce == nil, !busy, let d = downSince, Date().timeIntervalSince(d) > 60 {
                announce = ("Pocket turned on", Date())
            }
            downSince = nil
            if let a = announce {
                announce = nil
                camera.note("Pocket ready (\(a.reason))")
                notify("Pocket ready", hasWiFiPassword ? "Connected and on \(wifiSSID). Recording will follow Screen Studio."
                                                         : "Connected over Bluetooth.")
            }
        } else {
            if downSince == nil, !busy { downSince = Date() }
            if let a = announce, Date().timeIntervalSince(a.at) > 120 {
                announce = nil
                camera.note("Pocket not ready 2 minutes after \(a.reason): \(camera.state.label)")
                notify("Pocket not ready", "\(camera.state.label). Check it's on and close to the Mac.")
            }
        }
    }

    var hasWiFiPassword: Bool { !wifiSSID.isEmpty && wifiPassword != nil }

    /// The home Wi-Fi password, read from the keychain once per launch. Reading it can make
    /// macOS ask for permission (each new build counts as a new app), so read it away from
    /// the main thread: the menu keeps working while the prompt waits for an answer.
    private var wifiPassword: String?

    private func loadWiFiPassword() {
        let ssid = wifiSSID
        guard !ssid.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let pw = WiFiKeychain.password(for: ssid)
            await MainActor.run {
                guard let self, self.wifiSSID == ssid else { return }
                self.wifiPassword = pw
                if pw != nil { self.camera.nudge("Wi-Fi password loaded") }
            }
        }
    }

    /// Saves the Wi-Fi details and moves the camera onto that network.
    func setUpWiFi(ssid: String, password: String) {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        wifiSSID = name
        if !password.isEmpty {
            WiFiKeychain.save(password, for: name)
            wifiPassword = password
        }
        guard let pw = wifiPassword else { loadWiFiPassword(); return }
        // A copy has the camera on its own hotspot; it puts the camera back when it's done.
        guard !camera.holdWiFi else { camera.note("Saved \(name); the camera joins it after the copy"); return }
        Task { await camera.joinWiFi(ssid: name, password: pw) }
    }

    // MARK: Probe

    /// `open OsmoSync.app --args --probe`: find the camera, pair, record ~6 seconds, stop.
    /// Everything goes to ~/Library/Logs/OsmoSync.log.
    private func runProbe() {
        camera.trace = true
        camera.note("PROBE: started")
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            // Bluetooth can take several seconds to power on; a saved camera then reconnects by itself.
            var scanned = false
            for _ in 0..<60 {
                switch camera.state {
                case .ready, .connecting, .waitingForApproval: break
                case .notAllowed: camera.note("PROBE: Bluetooth not allowed"); return
                default:
                    if let cam = camera.found.max(by: { $0.rssi < $1.rssi }) {
                        camera.note("PROBE: connecting to \(cam.name)")
                        camera.connect(to: cam.id)
                    } else if camera.bluetoothOn, !scanned, !camera.hasSavedCamera || camera.state != .idle {
                        scanned = true
                        camera.scan()
                    }
                    await wait(0.5)
                    continue
                }
                break
            }
            for _ in 0..<120 where !camera.state.isReady {
                if case .failed = camera.state { camera.note("PROBE: gave up: \(camera.state.label)"); return }
                await wait(0.5)
            }
            guard camera.state.isReady else { camera.note("PROBE: not connected after 60s"); return }
            await wait(3)
            for _ in 0..<400 where camera.wifiBusy { await wait(0.5) }
            camera.note("PROBE: Wi-Fi link \(camera.wifiLinkOpen ? "open" : "not open") \(camera.wifiStatus)")
            camera.note("PROBE: status \(camera.status.map { "\($0.modeName), recording \($0.isRecording)" } ?? "none yet")")
            if CommandLine.arguments.contains("--variants") {
                // seq big-endian on the wire; a small seq; the camera as receiver id 1 type 1.
                for (label, seq, rx) in [("seq BE", UInt16(0x0381), UInt8(0x01)), ("seq small", UInt16(0x0004), UInt8(0x01)),
                                          ("rx 0x21", UInt16(0x8105), UInt8(0x21))] {
                    camera.note("PROBE: start variant \(label)")
                    camera.probeRecord(start: true, seq: seq, receiver: rx)
                    await wait(5)
                    camera.note("PROBE: stop variant \(label)")
                    camera.probeRecord(start: false, seq: seq &+ 0x0100, receiver: rx)
                    await wait(4)
                }
            } else if CommandLine.arguments.contains("--media") {
                await camera.probeMedia()
            } else {
                let started = await camera.startRecording()
                camera.note("PROBE: start -> \(started)")
                await wait(6)
                let stopped = await camera.stopRecording()
                camera.note("PROBE: stop -> \(stopped)")
            }
            await wait(2)
            camera.trace = false
            camera.note("PROBE: done")
        }
    }

    // MARK: Screen Studio

    private func restartWatcher() {
        timer?.invalidate()
        tailer = ScreenStudioLogTailer(projectsFolder: projectsFolder)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollScreenStudio() }
        }
    }

    private func pollScreenStudio() {
        guard let tailer else { return }
        let hits = tailer.poll()
        for (i, hit) in hits.enumerated() {
            switch hit.event {
            case .starting:
                // Never start the camera for a recording that has already ended: a start seen
                // together with its own stop, or a start line from long ago.
                if hits[(i + 1)...].contains(where: { $0.event != .starting }) {
                    camera.note("Screen Studio start and stop arrived together; not starting the camera")
                    continue
                }
                if let t = hit.time, Date().timeIntervalSince(t) > 30 {
                    camera.note("Ignoring a Screen Studio start from \(Int(Date().timeIntervalSince(t)))s ago")
                    continue
                }
                screenStudioStarted(project: hit.project, at: hit.time ?? Date())
            case .stopping, .stopped: screenStudioStopped(at: hit.time ?? Date())
            }
        }
    }

    private func screenStudioStarted(project: URL, at time: Date) {
        guard !screenStudioRecording else { return }
        screenStudioRecording = true
        let name = project.deletingPathExtension().lastPathComponent
        var take = Take(name: name, start: time, cameraStarted: false)
        camera.note("Screen Studio started recording: \(name)")
        guard autoRecord else { addTake(take); return }
        addTake(take)
        // Say so at once if the camera can't be reached, rather than after the take.
        let reachable = camera.state.isReady && camera.wifiReady
        if !reachable { notify(Self.unreachableTitle, Self.unreachableBody) }
        if WebcamUse.osmoInUse() {
            // The camera's own recording follows the webcam format while it streams.
            camera.note("The Osmo is streaming as a webcam, so this take records at webcam quality")
            notify("Osmo will record at webcam quality",
                   "Screen Studio is using the Osmo as its webcam. Turn the camera off in Screen Studio to record in 4K 60.")
        }
        startTask = Task {
            let ok = await camera.startRecording()
            take.cameraStarted = ok
            if ok { take.cameraStartedAt = Date() }
            updateTake(take)
            if !ok {
                if reachable, screenStudioRecording {
                    notify("Osmo didn't start", camera.wifiLinkOpen ? "The camera didn't confirm recording." : Self.unreachableBody)
                }
                // Get the camera back on Wi-Fi now, so the next take records.
                if camera.state.isReady, !camera.wifiLinkOpen { await camera.reconnectWiFi(reason: "Record failed") }
            } else if !reachable {
                notify("Osmo is recording", "The camera reconnected and started.")
            }
            return ok
        }
    }

    private func screenStudioStopped(at time: Date) {
        guard screenStudioRecording else { return }
        screenStudioRecording = false
        camera.note("Screen Studio stopped recording")
        guard var take = takes.first(where: \.isOpen) else { return }
        take.end = time
        updateTake(take)
        // Stop the camera if OsmoSync started it for this take, even if "Record on the Osmo"
        // was switched off mid-take: otherwise the camera keeps recording on its own.
        let pending = startTask
        startTask = nil
        guard pending != nil || take.cameraStarted else { return }
        Task {
            // If the start is still in flight, let it finish, then stop: otherwise the camera
            // would start after Screen Studio has already stopped and keep recording.
            let started = await pending?.value ?? false
            guard started || camera.isRecording || take.cameraStarted else { return }
            let stopped = await camera.stopRecording()
            guard autoImport, stopped else { return }
            if cameraCardMounted {
                importPending()
            } else {
                await copyWhenCool(take)
            }
        }
    }

    // MARK: Copy over the camera's hotspot

    /// Takes waiting for the camera to cool before their automatic copy.
    private var coolQueue: [UUID] = []

    /// Automatic copies wait until the camera has rested five minutes after recording, isn't
    /// flagged hot, and isn't streaming as a webcam (up to an hour). Copying over the hotspot
    /// straight after a take, with the webcam live, is what made the Pocket overheat.
    /// "Copy over Wi-Fi" in the menu still copies at once.
    func copyWhenCool(_ take: Take) async {
        guard !coolQueue.contains(take.id) else { return }
        coolQueue.append(take.id)
        guard coolQueue.count == 1 else { return }   // the running wait copies this one too
        let gate = CopyGate()
        let since = Date()
        var said = ""
        while !coolQueue.isEmpty {
            let verdict = gate.check(now: Date(), waitingSince: since,
                                     recording: screenStudioRecording || camera.isRecording,
                                     lastRecordingEnded: camera.lastRecordingEnded,
                                     webcamInUse: WebcamUse.osmoInUse(), lastHot: camera.lastHot)
            if case .wait(let why) = verdict {
                if why != said { camera.note("Copy waiting: \(why)"); said = why }
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            let id = coolQueue.removeFirst()
            guard let t = takes.first(where: { $0.id == id }), t.needsImport else { continue }
            camera.note("Camera rested; copying \(t.name)")
            await copyOverHotspot(t)
        }
    }

    /// Copies the newest take waiting for import, over the camera's hotspot.
    func copyLatestOverHotspot() {
        guard let take = takes.first(where: \.needsImport) else { camera.note("Nothing waiting to copy"); return }
        Task { await copyOverHotspot(take) }
    }

    /// The camera serves files only on its own hotspot. So: list the take's clips over your
    /// Wi-Fi, switch the camera to its hotspot, move the Mac's Wi-Fi onto it, download, then
    /// put both back on your network. A wired connection keeps the Mac online meanwhile.
    func copyOverHotspot(_ take: Take) async {
        guard hotspotStatus.isEmpty, !importing else { return }
        func status(_ s: String) { hotspotStatus = s; camera.note(s) }
        func usbFallback(_ why: String) {
            hotspotStatus = ""
            camera.note("Wi-Fi copy didn't run: \(why)")
            var t = take
            t.importNote = "not copied: \(why)"
            updateTake(t)
            notify("Copy the Osmo clip", "\(why) Open OsmoSync and press Copy over Wi-Fi to try again.")
        }
        guard camera.state.isReady else { return usbFallback("The camera isn't connected over Bluetooth.") }
        guard let home = camera.wifiCredentials?() else { return usbFallback("OsmoSync doesn't have your Wi-Fi password.") }
        guard !camera.isRecording else { return usbFallback("The camera is still recording.") }

        camera.holdWiFi = true
        copyingTake = take.id
        copyProgress = ""
        // Keep the Mac awake (and the app out of App Nap) for the whole copy; a large clip
        // takes minutes, longer with retries.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Copying a clip from the Osmo Pocket")
        defer {
            camera.holdWiFi = false
            copyingTake = nil
            copyProgress = ""
            ProcessInfo.processInfo.endActivity(activity)
        }
        status("Finding the clip on the camera")
        if !camera.wifiLinkOpen { await camera.findOnNetwork(within: 15) }
        var listed = await camera.listClips()
        var wanted = OsmoClips.pick(listed.map(\.path), takeStart: take.start, takeEnd: take.end ?? take.start)
        if wanted.isEmpty {
            // A Wi-Fi link that has been open a long while can keep answering commands yet stop
            // sending the clip list. A fresh link fixes it, so reconnect and ask once more.
            camera.note("No matching clip listed; reopening the Wi-Fi link and asking again")
            camera.disconnectWiFi()
            await camera.findOnNetwork(within: 20)
            listed = await camera.listClips()
            wanted = OsmoClips.pick(listed.map(\.path), takeStart: take.start, takeEnd: take.end ?? take.start)
        }
        let clips = wanted.compactMap { w in listed.first { $0.path == w } }
        guard !clips.isEmpty else { return usbFallback("No clip on the camera matches this take.") }
        guard let login = await camera.hotspotLogin() else { return usbFallback("The camera didn't share its hotspot login.") }

        // Moving the camera to its hotspot takes it off your network, so never during a take.
        guard !screenStudioRecording, !camera.isRecording else { return usbFallback("A recording started.") }
        let wired = MacWiFi.wiredOnline
        let busy = wired ? "Copying clip…" : "Copying clip… internet paused"
        status(busy)
        var copied: [String] = []
        var sources: [Take.CameraFile] = []
        var problem: String?
        do {
            func onHotspot() -> Bool { MacWiFi.wifiAddress?.hasPrefix("192.168.2.") == true }
            func joinHotspot(tries: Int) async -> Bool {
                for attempt in 1...tries {
                    if let msg = await MacWiFi.join(login.ssid, password: login.password) {
                        camera.note("Mac join try \(attempt): \(msg)")
                    }
                    if await MacWiFi.waitForWiFi({ $0.hasPrefix("192.168.2.") }, within: 12) { return true }
                }
                return false
            }
            // The Pocket shuts its hotspot down about a minute in unless an app holds its
            // command link open on it, so open the link on the hotspot and keep it for the copy.
            func holdHotspotLink() async {
                camera.disconnectWiFi()
                let ok = await camera.findOnNetwork(within: 8)
                camera.note("Command link on the camera hotspot: \(ok ? "open" : "not answering")")
            }
            // Get the camera's hotspot up and the Mac on it. The camera sometimes answers
            // "hotspot" but stays on your network; ask again, with backoff, before failing.
            func reachHotspot() async -> Bool {
                let reach = HotspotReach()
                for attempt in 1...reach.attempts {
                    switch reach.step(attempt: attempt) {
                    case .switchToHotspot:
                        _ = await camera.switchToHotspot()
                    case .restartHotspot(let wait):
                        if screenStudioRecording || camera.isRecording { return false }
                        status("Camera hotspot didn't come up; asking again (try \(attempt) of \(reach.attempts))")
                        try? await Task.sleep(for: .seconds(wait))
                        if screenStudioRecording || camera.isRecording { return false }
                        _ = await camera.restartHotspot()
                    case .giveUp:
                        return false
                    }
                    guard reach.shouldJoin(confirmed: camera.hotspotConfirmed, attempt: attempt) else {
                        camera.note("Camera didn't confirm its hotspot (try \(attempt))")
                        continue
                    }
                    if await joinHotspot(tries: camera.hotspotConfirmed ? 4 : 2) { return true }
                    camera.note("Mac couldn't find the camera hotspot (try \(attempt))")
                }
                return false
            }
            let joined = await reachHotspot()
            if joined { await holdHotspotLink() }
            if joined {
                camera.note("Mac on the camera hotspot")
                let fm = FileManager.default
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for (i, clip) in clips.enumerated() {
                    guard let (storage, size) = await CameraDownload.locate(clip.path, prefer: clip.storage) else {
                        problem = "The camera didn't serve \((clip.path as NSString).lastPathComponent)"
                        break
                    }
                    let suffix = clips.count > 1 ? " part \(i + 1)" : ""
                    var target = destination.appendingPathComponent("\(take.name) - Osmo\(suffix).MP4")
                    var n = 2
                    while fm.fileExists(atPath: target.path) {
                        target = destination.appendingPathComponent("\(take.name) - Osmo\(suffix) (\(n)).MP4"); n += 1
                    }
                    let mb = Double(size) / 1_048_576
                    let started = Date()
                    let partLabel = clips.count > 1 ? "part \(i + 1) of \(clips.count): " : ""
                    var rejoinFailed = false
                    do {
                        try await CameraDownload.fetch(clip.path, storage: storage, size: size, to: target, progress: { done in
                            Task { @MainActor in
                                let pct = Int(Double(done) * 100 / Double(max(size, 1)))
                                self.copyProgress = "Copying \(partLabel)\(pct)% of \(Int(mb)) MB"
                                if let at = self.dropWiFiAt, pct >= at {
                                    self.dropWiFiAt = nil
                                    self.camera.note("BIG COPY TEST: turning the Mac's Wi-Fi off for 5 s at \(pct)%")
                                    Task.detached {
                                        MacWiFi.run(["-setairportpower", MacWiFi.device, "off"])
                                        try? await Task.sleep(for: .seconds(5))
                                        MacWiFi.run(["-setairportpower", MacWiFi.device, "on"])
                                    }
                                }
                                self.hotspotStatus = "\(busy) \(pct)% of \(Int(mb)) MB"
                            }
                        }, shouldStop: {
                            await MainActor.run { self.screenStudioRecording || self.camera.isRecording }
                        }, recover: { h in
                            await MainActor.run {
                                self.camera.note(String(format: "Copy hiccup at %.0f MB (try %d): %@",
                                                        Double(h.offset) / 1_048_576, h.attempt, h.error.localizedDescription))
                            }
                            // Never keep the camera off your Wi-Fi once a take starts.
                            if await MainActor.run(body: { self.screenStudioRecording || self.camera.isRecording }) { return false }
                            let pct = Int(Double(h.offset) * 100 / Double(max(size, 1)))
                            let retrying = "Retrying (attempt \(h.attempt) of \(CopyRetry().maxAttempts))… \(pct)% copied"
                            await MainActor.run { self.copyProgress = retrying; self.hotspotStatus = "\(busy) \(retrying)" }
                            switch CopyRetry().step(attempt: h.attempt, macOnHotspot: onHotspot(), rejoinFailedBefore: rejoinFailed) {
                            case .retry:
                                break
                            case .rejoinMac:
                                camera.note("Mac left the camera hotspot; joining it again")
                                rejoinFailed = !(await joinHotspot(tries: 2))
                            case .restartHotspot:
                                camera.note("Asking the camera to restart its hotspot")
                                if await camera.restartHotspot() {
                                    rejoinFailed = !(await joinHotspot(tries: 3))
                                } else {
                                    rejoinFailed = true
                                }
                            }
                            if onHotspot() { await holdHotspotLink() }
                            camera.note(onHotspot() ? "Mac on the camera hotspot; resuming" : "Mac still off the camera hotspot")
                            return true
                        })
                        let secs = max(Date().timeIntervalSince(started), 0.1)
                        camera.note(String(format: "Copied %@ (%.0f MB in %.0fs, %.0f MB/s)", target.lastPathComponent, mb, secs, mb / secs))
                        copied.append(target.path)
                        if storage == clip.storage {
                            sources.append(Take.CameraFile(local: target.path, path: clip.path, storage: storage, size: size,
                                                           listedSize: clip.size, handle: clip.handle))
                        }
                    } catch is CancellationError {
                        problem = "A recording started; the rest copies next time"
                        break
                    } catch {
                        problem = error.localizedDescription
                        break
                    }
                }
            } else {
                problem = "The camera's hotspot didn't come up after 3 tries"
            }
        }

        // Put everything back, whatever happened above.
        camera.disconnectWiFi()
        status("Rejoining \(home.ssid)")
        if let msg = await MacWiFi.join(home.ssid, password: home.password) { camera.note("Mac rejoin: \(msg)") }
        let back = await MacWiFi.waitForWiFi({ !$0.hasPrefix("192.168.2.") && !$0.hasPrefix("169.254.") }, within: 30)
        await MacWiFi.forget(login.ssid)
        let online = await MacWiFi.internetUp(within: 30)
        camera.note("Mac back on \(home.ssid): \(back), internet: \(online)")
        status("Putting the camera back on \(home.ssid)")
        let camBack = await camera.joinWiFi(ssid: home.ssid, password: home.password)
        camera.note("Camera back on Wi-Fi: \(camBack)")
        hotspotStatus = ""

        var t = take
        if !copied.isEmpty {
            t.imported = copied
            t.cameraFiles = sources
            t.importNote = "Copied \(copied.count) clip\(copied.count == 1 ? "" : "s") over Wi-Fi"
            notify("Osmo clip copied", "\(take.name) → \(destination.lastPathComponent)")
        } else {
            t.importNote = problem ?? "Wi-Fi copy failed"
            notify("Copy the Osmo clip", "\(t.importNote ?? "") Open OsmoSync and press Copy over Wi-Fi to try again.")
        }
        camera.note("\(take.name): \(t.importNote ?? "")")
        updateTake(t)
        if !copied.isEmpty, autoDelete {
            if camBack, let fresh = takes.first(where: { $0.id == take.id }) {
                await removeFromCamera(fresh)
            } else {
                var k = t
                k.deleteNote = "Kept on the camera: it didn't come back on Wi-Fi to delete"
                updateTake(k)
            }
        }
        if !copied.isEmpty { await checkQuality(take.id) }
        if !copied.isEmpty, autoLineUp, let fresh = takes.first(where: { $0.id == take.id }) { await lineUp(fresh) }
        if !online { notify("Check your internet", "OsmoSync put the Mac back on \(home.ssid) but couldn't reach the internet.") }
    }

    // MARK: Remove clips from the camera

    /// Deletes a take's clips from the camera, one at a time, each only after its copy passes
    /// every check. Anything in doubt stays on the camera.
    func removeFromCamera(_ take: Take) async {
        guard let files = take.cameraFiles, !files.isEmpty else { return }
        var t = take
        var removed = 0
        var kept: [String] = []
        let expected = take.end.map { $0.timeIntervalSince(take.cameraStartedAt ?? take.start) }
        for f in files {
            let name = (f.path as NSString).lastPathComponent
            guard !screenStudioRecording, !camera.isRecording else { kept.append("a recording started"); break }
            let local = URL(fileURLWithPath: f.local)
            let size = Self.fileSize(local)
            let duration = await Self.videoDuration(local)
            let verdict = DeleteCheck.verdict(localSize: size, servedSize: f.size, listedSize: f.listedSize,
                                              handle: f.handle, duration: duration, expectedDuration: expected)
            if case .keep(let why) = verdict {
                camera.note("Kept \(name) on the camera: \(why)")
                kept.append(why)
                continue
            }
            switch await camera.deleteClip(path: f.path, storage: f.storage, size: f.size) {
            case .deleted:
                removed += 1
                camera.note("Removed \(name).MP4 (\(Self.sizeText(f.size))) from the camera")
            case .kept(let why), .unsure(let why):
                camera.note("Kept \(name) on the camera: \(why)")
                kept.append(why)
            }
        }
        if removed == files.count {
            t.removedFromCamera = true
            t.deleteNote = "Removed from camera"
        } else {
            t.removedFromCamera = false
            t.deleteNote = "Kept on the camera: \(kept.first ?? "not checked")"
        }
        updateTake(t)
    }

    /// One camera clip that "Clean up camera" would delete.
    struct CleanupItem {
        var clip: OsmoCamera.CameraClip
        var local: URL
        var size: Int64
    }

    /// Finds camera clips that already have a checked copy in the save folder: same size to
    /// the byte (the camera's list carries the low 32 bits), recorded during the take that
    /// copied it, and readable as video of about the right length. Deletes nothing.
    func cleanupCandidates() async -> [CleanupItem] {
        if !camera.wifiLinkOpen { await camera.findOnNetwork(within: 15) }
        let listed = await camera.listClips()
        guard !camera.lastListAnswered.isEmpty else { camera.note("Clean up: the camera didn't send its clip list"); return [] }
        var out: [CleanupItem] = []
        var used = Set<String>()
        for take in takes where !take.imported.isEmpty && take.removedFromCamera != true {
            let window = OsmoClips.pick(listed.map(\.path), takeStart: take.start, takeEnd: take.end ?? take.start)
            let expected = take.end.map { $0.timeIntervalSince(take.cameraStartedAt ?? take.start) }
            for path in window {
                guard let clip = listed.first(where: { $0.path == path }), clip.handle != 0, clip.size != 0,
                      camera.lastListAnswered.contains(clip.storage),
                      !used.contains(path) else { continue }
                for file in take.imported where !used.contains(file) {
                    let url = URL(fileURLWithPath: file)
                    guard let size = Self.fileSize(url), UInt32(truncatingIfNeeded: size) == clip.size else { continue }
                    let duration = await Self.videoDuration(url)
                    let verdict = DeleteCheck.verdict(localSize: size, servedSize: size, listedSize: clip.size,
                                                      handle: clip.handle, duration: duration, expectedDuration: expected)
                    guard verdict == .safe else { continue }
                    out.append(CleanupItem(clip: clip, local: url, size: size))
                    used.insert(path); used.insert(file)
                    break
                }
            }
        }
        let total = out.reduce(Int64(0)) { $0 + $1.size }
        camera.note("Clean up would remove \(out.count) of \(listed.count) camera clip\(listed.count == 1 ? "" : "s"), \(Self.sizeText(total))")
        for item in out { camera.note("  \(item.clip.path) = \(item.local.lastPathComponent)") }
        return out
    }

    /// "Clean up camera…": shows what it would remove and asks before deleting anything.
    func cleanUpCamera() {
        guard cleanupStatus.isEmpty, hotspotStatus.isEmpty else { return }
        guard camera.state.isReady else { camera.note("Clean up: connect the camera first"); return }
        guard !screenStudioRecording, !camera.isRecording else { camera.note("Clean up: not while recording"); return }
        cleanupStatus = "Checking the camera's clips…"
        Task {
            camera.holdWiFi = true
            defer { camera.holdWiFi = false; cleanupStatus = "" }
            let items = await cleanupCandidates()
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            let alert = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard !items.isEmpty else {
                alert.messageText = "Nothing to clean up"
                alert.informativeText = "No clip on the camera has a checked copy in \(destination.lastPathComponent)."
                alert.runModal()
                return
            }
            alert.messageText = "Remove \(items.count) clip\(items.count == 1 ? "" : "s") from the camera?"
            alert.informativeText = "This frees \(Self.sizeText(total)) on the Pocket. Each clip already has a checked copy in \(destination.lastPathComponent). Other clips stay on the camera. This can't be undone on the camera."
            alert.addButton(withTitle: "Remove from camera")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { camera.note("Clean up cancelled"); return }
            var removed = 0
            var freed: Int64 = 0
            for (i, item) in items.enumerated() {
                guard !screenStudioRecording, !camera.isRecording else { camera.note("Clean up stopped: a recording started"); break }
                cleanupStatus = "Removing clip \(i + 1) of \(items.count)…"
                let name = (item.clip.path as NSString).lastPathComponent
                if await camera.deleteClip(path: item.clip.path, storage: item.clip.storage, size: item.size) == .deleted {
                    removed += 1; freed += item.size
                    camera.note("Removed \(name).MP4 (\(Self.sizeText(item.size))) from the camera")
                    markRemoved(local: item.local.path)
                } else {
                    camera.note("Kept \(name) on the camera")
                }
            }
            camera.note("Clean up: removed \(removed) of \(items.count), freed \(Self.sizeText(freed))")
            notify("Camera cleaned up", "Removed \(removed) clip\(removed == 1 ? "" : "s"), freed \(Self.sizeText(freed)).")
        }
    }

    private func markRemoved(local: String) {
        guard var t = takes.first(where: { $0.imported.contains(local) }) else { return }
        t.removedFromCamera = true
        t.deleteNote = "Removed from camera"
        updateTake(t)
    }

    nonisolated static func fileSize(_ url: URL) -> Int64? {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
        return n.int64Value
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Seconds of video in the file, read by ffprobe (which reads the whole index), or by
    /// AVFoundation if ffprobe isn't installed. Nil if neither can read it.
    nonisolated static func videoDuration(_ url: URL) async -> Double? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "\(home)/.local/homebrew/bin/ffprobe"]
        if let probe = probes.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let out: Double? = await Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: probe)
                p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { return nil }
                return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }.value
            return out
        }
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return nil }
        return d.seconds
    }

    /// Manual start/stop for testing without Screen Studio.
    func testRecord() {
        Task {
            if camera.isRecording { await camera.stopRecording() } else { await camera.startRecording() }
        }
    }

    // MARK: Line up with Screen Studio

    /// Writes "<take> - Osmo (synced).mov", which starts at the same moment as the screen recording.
    /// Reads each copied clip's size and frame rate, and says so on the take when it came
    /// out below 4K 60.
    func checkQuality(_ id: UUID) async {
        guard var t = takes.first(where: { $0.id == id }) else { return }
        var notes: [String] = []
        for f in t.imported {
            guard let q = await Self.clipQuality(URL(fileURLWithPath: f)) else { continue }
            camera.note("\(URL(fileURLWithPath: f).lastPathComponent): \(q.summary)")
            if let n = q.shortfall() { notes.append(n) }
        }
        t.qualityNote = notes.first
        updateTake(t)
        if let n = notes.first { notify("Osmo clip below 4K 60", n) }
    }

    nonisolated static func clipQuality(_ url: URL) async -> ClipQuality? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        else { return nil }
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return ClipQuality(width: Int(abs(r.width).rounded()), height: Int(abs(r.height).rounded()), fps: Double(fps))
    }

    func lineUp(_ take: Take) async {
        guard let clip = take.imported.first.map(URL.init(fileURLWithPath:)) else { return }
        let project = projectsFolder.appendingPathComponent("\(take.name).screenstudio")
        var t = take
        t.syncNote = "Lining up…"
        updateTake(t)
        camera.note("Lining up \(clip.lastPathComponent) with \(project.lastPathComponent)")
        do {
            let o = try await LineUp.run(clip: clip, project: project, cameraStart: take.cameraStartedAt) { [weak self] in
                self?.camera.note($0)
            }
            t.synced = o.output.path
            t.syncNote = String(format: "Synced (offset %.2f s%@)", o.offset, o.method == "audio" ? "" : ", by clock")
            camera.note("\(t.syncNote!) → \(o.output.lastPathComponent)")
        } catch {
            t.syncNote = "Not synced: \(error.localizedDescription)"
            camera.note(t.syncNote!)
        }
        updateTake(t)
    }

    // MARK: Takes

    private func addTake(_ t: Take) {
        takes.insert(t, at: 0)
        if takes.count > 50 { takes.removeLast(takes.count - 50) }
        saveTakes()
    }

    private func updateTake(_ t: Take) {
        guard let i = takes.firstIndex(where: { $0.id == t.id }) else { return }
        // Merge: the record task may finish after stop has already set `end`.
        var merged = takes[i]
        merged.cameraStarted = merged.cameraStarted || t.cameraStarted
        merged.end = merged.end ?? t.end
        merged.imported = t.imported.isEmpty ? merged.imported : t.imported
        merged.importNote = t.importNote ?? merged.importNote
        merged.cameraStartedAt = merged.cameraStartedAt ?? t.cameraStartedAt
        merged.synced = t.synced ?? merged.synced
        merged.syncNote = t.syncNote ?? merged.syncNote
        merged.cameraFiles = t.cameraFiles ?? merged.cameraFiles
        merged.removedFromCamera = t.removedFromCamera ?? merged.removedFromCamera
        merged.deleteNote = t.deleteNote ?? merged.deleteNote
        takes[i] = merged
        saveTakes()
    }

    private func saveTakes() {
        if let data = try? JSONEncoder().encode(takes) { defaults.set(data, forKey: "takes") }
    }

    func clearTakes() { takes.removeAll(where: { !$0.isOpen }); saveTakes() }

    // MARK: Import

    private func cameraVolumes() -> [URL] {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return vols.filter { $0.path != "/" && CameraMedia.isCameraVolume($0) }
    }

    private func volumeMounted(_ url: URL) {
        guard CameraMedia.isCameraVolume(url) else { return }
        camera.note("Camera card mounted: \(url.lastPathComponent)")
        if autoImport { importPending() }
    }

    var cameraCardMounted: Bool { !cameraVolumes().isEmpty }

    /// Copies the clips for every finished take that hasn't been imported yet.
    func importPending() {
        guard !importing else { return }
        let pending = takes.filter(\.needsImport)
        guard !pending.isEmpty else { camera.note("Nothing waiting to import"); return }
        let volumes = cameraVolumes()
        guard !volumes.isEmpty else {
            camera.note("Waiting for the camera's card. Pick 'File transfer' on the Osmo's USB prompt.")
            return
        }
        importing = true
        let dest = destination
        Task.detached(priority: .utility) {
            let files = volumes.flatMap { CameraMedia.videos(on: $0) }
            var results: [(Take, [String], String?)] = []
            for take in pending {
                var clips = CameraMedia.clips(files, takeStart: take.start, takeEnd: take.end ?? take.start)
                // The camera's clock can drift from the Mac's. With a single take waiting,
                // fall back to the newest clip if it was written within a few hours.
                if clips.isEmpty, pending.count == 1, let newest = files.first,
                   abs(newest.modified.timeIntervalSince(take.end ?? take.start)) < 6 * 3600 {
                    clips = [newest.url]
                }
                if clips.isEmpty { results.append((take, [], "No matching clip on the card yet")); continue }
                do {
                    let copied = try Self.copy(clips, named: take.name, to: dest)
                    results.append((take, copied, nil))
                } catch {
                    results.append((take, [], "Copy failed: \(error.localizedDescription)"))
                }
            }
            let finished = results
            await MainActor.run {
                for (take, copied, note) in finished {
                    var t = take
                    t.imported = copied
                    t.importNote = note ?? "Copied \(copied.count) clip\(copied.count == 1 ? "" : "s")"
                    self.updateTake(t)
                    self.camera.note("\(take.name): \(t.importNote ?? "")")
                    if !copied.isEmpty { self.notify("Osmo clip imported", "\(take.name) → \(dest.lastPathComponent)") }
                }
                self.importing = false
                let checked = finished.filter { !$0.1.isEmpty }.map(\.0.id)
                Task { @MainActor in for id in checked { await self.checkQuality(id) } }
                if self.autoLineUp {
                    let ids = Set(finished.filter { !$0.1.isEmpty }.map(\.0.id))
                    Task { @MainActor in
                        for t in self.takes where ids.contains(t.id) { await self.lineUp(t) }
                    }
                }
            }
        }
    }

    nonisolated private static func copy(_ clips: [URL], named name: String, to dest: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var out: [String] = []
        for (i, clip) in clips.enumerated() {
            let suffix = clips.count > 1 ? " part \(i + 1)" : ""
            var target = dest.appendingPathComponent("\(name) - Osmo\(suffix).\(clip.pathExtension)")
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = dest.appendingPathComponent("\(name) - Osmo\(suffix) (\(n)).\(clip.pathExtension)")
                n += 1
            }
            try fm.copyItem(at: clip, to: target)
            out.append(target.path)
        }
        return out
    }

    func revealDestination() {
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        NSWorkspace.shared.open(destination)
    }

    func choose(folderFor keyPath: ReferenceWritableKeyPath<AppModel, URL>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = self[keyPath: keyPath]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { self[keyPath: keyPath] = url }
    }

    static let unreachableTitle = "Pocket not connected"
    static let unreachableBody = "This take won't record on the camera. OsmoSync is reconnecting it."

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
