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

    var isOpen: Bool { end == nil }
    var needsImport: Bool { end != nil && cameraStarted && imported.isEmpty }
}

@MainActor
final class AppModel: ObservableObject {
    let camera = OsmoCamera()

    @Published var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "autoRecord") } }
    @Published var autoImport: Bool { didSet { defaults.set(autoImport, forKey: "autoImport") } }
    @Published var projectsFolder: URL { didSet { defaults.set(projectsFolder.path, forKey: "projectsFolder"); restartWatcher() } }
    @Published var destination: URL { didSet { defaults.set(destination.path, forKey: "destination") } }
    @Published private(set) var takes: [Take] = []
    @Published private(set) var screenStudioRecording = false
    @Published private(set) var importing = false
    /// Home Wi-Fi the camera joins so the Mac can start and stop it. Password lives in the keychain.
    @Published var wifiSSID: String { didSet { defaults.set(wifiSSID, forKey: "wifiSSID") } }

    private let defaults = UserDefaults.standard
    private var tailer: ScreenStudioLogTailer?
    private var timer: Timer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        autoRecord = defaults.object(forKey: "autoRecord") as? Bool ?? true
        autoImport = defaults.object(forKey: "autoImport") as? Bool ?? true
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
            guard let self, !self.wifiSSID.isEmpty, let pw = WiFiKeychain.password(for: self.wifiSSID) else { return nil }
            return (self.wifiSSID, pw)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.volumeMounted(url) }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if CommandLine.arguments.contains("--probe") { runProbe() }
    }

    var hasWiFiPassword: Bool { !wifiSSID.isEmpty && WiFiKeychain.password(for: wifiSSID) != nil }

    /// Saves the Wi-Fi details and moves the camera onto that network.
    func setUpWiFi(ssid: String, password: String) {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        wifiSSID = name
        if !password.isEmpty { WiFiKeychain.save(password, for: name) }
        guard let pw = WiFiKeychain.password(for: name) else { return }
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
        for hit in tailer.poll() {
            switch hit.event {
            case .starting: screenStudioStarted(project: hit.project, at: hit.time ?? Date())
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
        Task {
            let ok = await camera.startRecording()
            take.cameraStarted = ok
            updateTake(take)
            if !ok { notify("Osmo didn't start", camera.state.isReady ? "The camera didn't confirm recording." : "The camera isn't connected.") }
        }
    }

    private func screenStudioStopped(at time: Date) {
        guard screenStudioRecording else { return }
        screenStudioRecording = false
        camera.note("Screen Studio stopped recording")
        guard var take = takes.first(where: \.isOpen) else { return }
        take.end = time
        updateTake(take)
        guard autoRecord, camera.isRecording || take.cameraStarted else { return }
        Task {
            await camera.stopRecording()
            if autoImport { importPending() }
        }
    }

    /// Manual start/stop for testing without Screen Studio.
    func testRecord() {
        Task {
            if camera.isRecording { await camera.stopRecording() } else { await camera.startRecording() }
        }
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

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
