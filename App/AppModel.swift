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

    var isOpen: Bool { end == nil }
    var needsImport: Bool { end != nil && cameraStarted && imported.isEmpty }
}

@MainActor
final class AppModel: ObservableObject {
    let camera = OsmoCamera()

    @Published var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "autoRecord") } }
    @Published var autoImport: Bool { didSet { defaults.set(autoImport, forKey: "autoImport") } }
    @Published var autoLineUp: Bool { didSet { defaults.set(autoLineUp, forKey: "autoLineUp") } }
    @Published var projectsFolder: URL { didSet { defaults.set(projectsFolder.path, forKey: "projectsFolder"); restartWatcher() } }
    @Published var destination: URL { didSet { defaults.set(destination.path, forKey: "destination") } }
    @Published private(set) var takes: [Take] = []
    @Published private(set) var screenStudioRecording = false
    @Published private(set) var importing = false
    /// What the Wi-Fi hotspot copy is doing, shown in the menu. Empty when idle.
    @Published private(set) var hotspotStatus = ""
    /// Home Wi-Fi the camera joins so the Mac can start and stop it. Password lives in the keychain.
    @Published var wifiSSID: String { didSet { defaults.set(wifiSSID, forKey: "wifiSSID") } }

    private let defaults = UserDefaults.standard
    private var tailer: ScreenStudioLogTailer?
    private var startTask: Task<Bool, Never>?
    private var timer: Timer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        autoRecord = defaults.object(forKey: "autoRecord") as? Bool ?? true
        autoImport = defaults.object(forKey: "autoImport") as? Bool ?? true
        autoLineUp = defaults.object(forKey: "autoLineUp") as? Bool ?? true
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
        if CommandLine.arguments.contains("--line-up") {
            // Test hook: line up every copied take that hasn't been lined up yet.
            Task { @MainActor in
                for take in takes where !take.imported.isEmpty && take.synced == nil { await lineUp(take) }
                camera.note("LINE-UP TEST: done")
            }
        }
        if CommandLine.arguments.contains("--copy-latest") {
            // Test hook: wait for the camera and its Wi-Fi link, then copy the newest waiting take.
            Task { @MainActor in
                for _ in 0..<180 where !(camera.state.isReady && camera.wifiLinkOpen) { try? await Task.sleep(for: .seconds(0.5)) }
                camera.note("COPY TEST: camera ready \(camera.state.isReady), Wi-Fi link \(camera.wifiLinkOpen)")
                guard let take = takes.first(where: \.needsImport) else { camera.note("COPY TEST: nothing waiting"); return }
                await copyOverHotspot(take)
                camera.note("COPY TEST: done")
            }
        }
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
        startTask = Task {
            let ok = await camera.startRecording()
            take.cameraStarted = ok
            if ok { take.cameraStartedAt = Date() }
            updateTake(take)
            if !ok, screenStudioRecording {
                notify("Osmo didn't start", camera.state.isReady ? "The camera didn't confirm recording." : "The camera isn't connected.")
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
                await copyOverHotspot(take)
            }
        }
    }

    // MARK: Copy over the camera's hotspot

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

        let wired = MacWiFi.wiredOnline
        let busy = wired ? "Copying clip…" : "Copying clip… internet paused"
        status(busy)
        var copied: [String] = []
        var problem: String?
        if await camera.switchToHotspot() {
            var joined = false
            for attempt in 1...4 where !joined {
                if let msg = await MacWiFi.join(login.ssid, password: login.password) {
                    camera.note("Mac join try \(attempt): \(msg)")
                }
                joined = await MacWiFi.waitForWiFi({ $0.hasPrefix("192.168.2.") }, within: 12)
            }
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
                    do {
                        try await CameraDownload.fetch(clip.path, storage: storage, size: size, to: target) { done in
                            Task { @MainActor in
                                self.hotspotStatus = "\(busy) \(Int(Double(done) * 100 / Double(size)))% of \(Int(mb)) MB"
                            }
                        }
                        let secs = max(Date().timeIntervalSince(started), 0.1)
                        camera.note(String(format: "Copied %@ (%.0f MB in %.0fs, %.0f MB/s)", target.lastPathComponent, mb, secs, mb / secs))
                        copied.append(target.path)
                    } catch {
                        problem = error.localizedDescription
                        break
                    }
                }
            } else {
                problem = "The Mac couldn't join the camera's hotspot"
            }
        } else {
            problem = "The camera didn't switch to its hotspot"
        }

        // Put everything back, whatever happened above.
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
            t.importNote = "Copied \(copied.count) clip\(copied.count == 1 ? "" : "s") over Wi-Fi"
            notify("Osmo clip copied", "\(take.name) → \(destination.lastPathComponent)")
        } else {
            t.importNote = problem ?? "Wi-Fi copy failed"
            notify("Copy the Osmo clip", "\(t.importNote ?? "") Open OsmoSync and press Copy over Wi-Fi to try again.")
        }
        camera.note("\(take.name): \(t.importNote ?? "")")
        updateTake(t)
        if !copied.isEmpty, autoLineUp, let fresh = takes.first(where: { $0.id == take.id }) { await lineUp(fresh) }
        if !online { notify("Check your internet", "OsmoSync put the Mac back on \(home.ssid) but couldn't reach the internet.") }
    }

    /// Manual start/stop for testing without Screen Studio.
    func testRecord() {
        Task {
            if camera.isRecording { await camera.stopRecording() } else { await camera.startRecording() }
        }
    }

    // MARK: Line up with Screen Studio

    /// Writes "<take> - Osmo (synced).mov", which starts at the same moment as the screen recording.
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

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
