import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var camera: OsmoCamera
    @State private var showLog = false
    @State private var ssid = ""
    @State private var password = ""
    @State private var editingWiFi = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .onAppear { camera.menuOpen = true }
                .onDisappear { camera.menuOpen = false }
            Divider()
            cameraSection
            if camera.state.isReady {
                Divider()
                CameraControlsView(camera: camera)
            }
            Divider()
            wifiSection
            Divider()
            toggles
            Divider()
            takesSection
            if showLog { logSection }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("OsmoSync").font(.headline)
            Spacer()
            Label(model.screenStudioRecording ? "Screen Studio recording" : "Screen Studio idle",
                  systemImage: model.screenStudioRecording ? "record.circle" : "display")
                .font(.caption)
                .foregroundStyle(model.screenStudioRecording ? .red : .secondary)
        }
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(camera.state.label).font(.callout).lineLimit(2)
            }
            if let s = camera.status {
                HStack(spacing: 12) {
                    Label(s.modeName, systemImage: "camera")
                    if s.isRecording { Label(timeString(s.recordSeconds), systemImage: "record.circle").foregroundStyle(.red) }
                    if let b = s.battery { Label("\(b)%", systemImage: "battery.75") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if s.isWebcamMode {
                    Text("Webcam mode can't record to the card. Use the Pocket in normal video mode.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if WebcamUse.osmoInUse() {
                Text("Screen Studio is using the Osmo as a webcam, so it records at webcam quality, not 4K 60. Turn the camera off in Screen Studio.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                switch camera.state {
                case .ready:
                    Button(camera.isRecording ? "Stop camera" : "Test record") { model.testRecord() }
                    Button("Disconnect") { camera.disconnect() }
                case .scanning, .connecting, .waitingForApproval:
                    Button("Cancel") { camera.disconnect() }
                default:
                    Button("Find camera") { camera.scan() }
                    if camera.hasSavedCamera { Button("Reconnect") { camera.reconnect() } }
                }
            }
            if !camera.state.isReady {
                ForEach(camera.found) { f in
                    Button { camera.connect(to: f.id) } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("Connect to \(f.name)")
                            Spacer()
                            Text("\(f.rssi) dBm").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }
        }
    }

    /// Osmo Pockets only take record commands over Wi-Fi, so the camera joins your network.
    private var wifiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Wi-Fi", systemImage: camera.wifiLinkOpen ? "wifi" : "wifi.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(camera.wifiLinkOpen ? .green : .primary)
                Spacer()
                if camera.wifiBusy { ProgressView().controlSize(.small) }
            }
            if !camera.wifiStatus.isEmpty {
                Text(camera.wifiStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if editingWiFi || model.wifiSSID.isEmpty {
                Text("The camera joins this network so the Mac can start and stop it. Use the network this Mac is on.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Wi-Fi name", text: $ssid).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect camera to Wi-Fi") {
                        model.setUpWiFi(ssid: ssid, password: password)
                        password = ""
                        editingWiFi = false
                    }
                    .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty || !camera.state.isReady || camera.wifiBusy
                               || model.copyingTake != nil)
                    if editingWiFi { Button("Cancel") { editingWiFi = false } }
                }
                if !camera.state.isReady {
                    Text("Connect the camera over Bluetooth first.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text(model.wifiSSID).font(.callout)
                    Spacer()
                    if !camera.wifiLinkOpen && model.copyingTake == nil {
                        Button("Retry") { model.setUpWiFi(ssid: model.wifiSSID, password: "") }
                            .disabled(!camera.state.isReady || camera.wifiBusy || !model.hasWiFiPassword)
                    }
                    Button("Change") { ssid = model.wifiSSID; editingWiFi = true }
                }
            }
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Record on the Osmo when Screen Studio records", isOn: $model.autoRecord)
            Toggle("Copy clips to the Mac when the camera's card mounts", isOn: $model.autoImport)
            Toggle("Line up clips with the Screen Studio recording", isOn: $model.autoLineUp)
            Toggle("Delete clips from the Pocket after copying", isOn: $model.autoDelete)
                .help("Only after the copy on the Mac is checked: same size, fully written, and plays as video.")
            HStack {
                Text("Save to").foregroundStyle(.secondary)
                Button(model.destination.lastPathComponent) { model.choose(folderFor: \.destination) }
                Spacer()
                Button { model.revealDestination() } label: { Image(systemName: "folder") }
                    .help("Open folder")
            }
            .font(.caption)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private var takesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Takes").font(.subheadline.weight(.semibold))
                Spacer()
                Button(model.importing ? "Copying…" : "Import now") { model.importPending() }
                    .disabled(model.importing)
            }
            if !model.hotspotStatus.isEmpty {
                Label(model.hotspotStatus, systemImage: "wifi")
                    .font(.caption).foregroundStyle(.blue)
            } else if model.takes.contains(where: \.needsImport), !model.cameraCardMounted, !model.importing {
                HStack {
                    Label("Clip still on the camera", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Copy over Wi-Fi") { model.copyLatestOverHotspot() }
                        .font(.caption)
                }
            }
            if !model.cleanupStatus.isEmpty {
                Label(model.cleanupStatus, systemImage: "trash").font(.caption).foregroundStyle(.blue)
            } else if camera.state.isReady && camera.wifiLinkOpen {
                Button("Clean up camera…") { model.cleanUpCamera() }
                    .font(.caption)
                    .disabled(model.screenStudioRecording || camera.isRecording || !model.hotspotStatus.isEmpty)
                    .help("Removes clips from the Pocket that already have a checked copy on this Mac. Asks first.")
            }
            if model.takes.isEmpty {
                Text("Start a recording in Screen Studio and the Osmo starts with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.takes.prefix(5)) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(.caption).lineLimit(1)
                    Text(takeLine(t)).font(.caption2).foregroundStyle(.secondary)
                    if model.coolQueue.contains(t.id) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(copyWaitText(now: ctx.date)).font(.caption2).foregroundStyle(.blue)
                        }
                    }
                    if t.id == model.copyingTake, !model.copyProgress.isEmpty {
                        Text(model.copyProgress).font(.caption2)
                            .foregroundStyle(model.copyProgress.hasPrefix("Retrying") ? .orange : .blue)
                    }
                    if let d = t.deleteNote {
                        Text(d).font(.caption2).foregroundStyle(t.removedFromCamera == true ? .green : .secondary)
                    }
                    if let q = t.qualityNote {
                        Text(q).font(.caption2).foregroundStyle(.orange)
                    }
                    if let s = t.syncNote {
                        Text(s).font(.caption2).foregroundStyle(s.hasPrefix("Synced") ? .green : .secondary)
                    }
                }
            }
        }
    }

    /// "Waiting to copy: starts in 3:12 (camera hot)".
    private func copyWaitText(now: Date) -> String {
        if let at = model.copyStartsAt, at > now {
            let left = Int(at.timeIntervalSince(now).rounded(.up))
            return String(format: "Waiting to copy: starts in %d:%02d (camera hot)", left / 60, left % 60)
        }
        return model.copyWaitReason.isEmpty ? "Copying soon" : "Waiting to copy: \(model.copyWaitReason)"
    }

    private var logSection: some View {
        ScrollView {
            Text(camera.log.suffix(60).joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 140)
    }

    private var footer: some View {
        HStack {
            Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private var dotColor: Color {
        switch camera.state {
        case .ready: camera.isRecording ? .red : .green
        case .failed, .notAllowed, .bluetoothOff: .orange
        default: .yellow
        }
    }

    private func timeString(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    private func takeLine(_ t: Take) -> String {
        let when = t.start.formatted(date: .abbreviated, time: .shortened)
        if t.isOpen { return "\(when) · recording" + (t.cameraStarted ? " on Osmo" : "") }
        if !t.cameraStarted { return "\(when) · Osmo didn't record" }
        if !t.imported.isEmpty { return "\(when) · copied \(t.imported.count) clip\(t.imported.count == 1 ? "" : "s")" }
        return "\(when) · " + (t.importNote ?? "still on the camera")
    }
}
