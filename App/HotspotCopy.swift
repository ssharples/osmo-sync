import Foundation
import OsmoSyncCore

/// Moves the Mac's Wi-Fi between your network and the camera's hotspot.
///
/// Uses `networksetup`: on macOS 26 CoreWLAN hides network names from apps without
/// Location access, so it can't find the camera's hotspot to join. Passwords go only
/// to `networksetup` and are never logged.
enum MacWiFi {
    /// The Wi-Fi device, usually `en0`.
    static let device: String = {
        let out = run(["-listallhardwareports"]).output
        let lines = out.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() where l.hasSuffix(": Wi-Fi") && i + 1 < lines.count {
            if let d = lines[i + 1].components(separatedBy: "Device: ").last, !d.isEmpty { return d }
        }
        return "en0"
    }()

    @discardableResult
    static func run(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Asks macOS to join a network. Returns networksetup's complaint, or nil if it said nothing.
    static func join(_ ssid: String, password: String) async -> String? {
        await Task.detached {
            let r = run(["-setairportnetwork", device, ssid, password])
            let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.status == 0 && text.isEmpty ? nil : (text.isEmpty ? "exit \(r.status)" : text)
        }.value
    }

    /// Stops macOS joining the camera's hotspot by itself later. Best effort; may need admin.
    static func forget(_ ssid: String) async {
        _ = await Task.detached { run(["-removepreferredwirelessnetwork", device, ssid]) }.value
    }

    /// IPv4 addresses on each up, non-loopback interface.
    static func addresses() -> [String: String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        var out: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            out[String(cString: ifa.ifa_name)] = String(cString: buf)
        }
        return out
    }

    static var wifiAddress: String? { addresses()[device] }

    /// True when a wired port (such as a USB Ethernet adapter) has an address, so the Mac
    /// stays online while its Wi-Fi is on the camera.
    static var wiredOnline: Bool {
        addresses().contains { name, ip in
            name.hasPrefix("en") && name != device && !ip.hasPrefix("169.254.")
        }
    }

    static func waitForWiFi(_ ok: (String) -> Bool, within s: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(s)
        while Date() < deadline {
            if let ip = wifiAddress, ok(ip) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// True once Apple's captive-portal check page loads.
    static func internetUp(within s: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(s)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: cfg)
        while Date() < deadline {
            if let (_, r) = try? await session.data(from: URL(string: "http://captive.apple.com/hotspot-detect.html")!),
               (r as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}

/// Resumable download from the camera's `/v2` file server, in 64 MB ranges written to
/// `<dest>.part` and renamed once the size matches. Same approach as OsmoOffload.
enum CameraDownload {
    enum Failure: LocalizedError {
        case notFound, sizeMismatch(Int64, Int64), gaveUp(String)
        var errorDescription: String? {
            switch self {
            case .notFound: "The camera didn't serve that clip"
            case .sizeMismatch(let got, let want): "Got \(got) of \(want) bytes"
            case .gaveUp(let why): "Download kept failing: \(why)"
            }
        }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Finds which storage serves `path` and how big it is.
    static func locate(_ path: String, prefer: Int) async -> (storage: Int, size: Int64)? {
        for storage in [prefer, 1 - prefer] {
            var req = URLRequest(url: OsmoClips.url(path: path, storage: storage))
            req.httpMethod = "HEAD"
            if let (_, r) = try? await session.data(for: req), let h = r as? HTTPURLResponse,
               h.statusCode == 200, h.expectedContentLength > 0 {
                return (storage, h.expectedContentLength)
            }
        }
        return nil
    }

    /// What the caller should know about a failed piece before the next try.
    struct Hiccup {
        var attempt: Int
        var offset: Int64
        var error: Error
        var wait: TimeInterval
    }

    /// Downloads `path` into `<dest>.part`, resuming from whatever is there, then renames it.
    ///
    /// On a failed piece it calls `recover` (which can get the Mac back on the hotspot),
    /// waits with backoff and carries on from the last byte saved. `recover` returns false
    /// to stop; the `.part` file stays so a later copy resumes from it.
    static func fetch(_ path: String, storage: Int, size: Int64, to dest: URL,
                      policy: CopyRetry = CopyRetry(),
                      progress: @escaping (Int64) -> Void,
                      shouldStop: () async -> Bool = { false },
                      recover: (Hiccup) async -> Bool = { _ in true }) async throws {
        let fm = FileManager.default
        let part = dest.appendingPathExtension("part")
        let existing = ((try? fm.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value
        var pos = CopyRange.resumePoint(partSize: existing, size: size)
        if pos == 0 || !fm.fileExists(atPath: part.path) {
            try? fm.removeItem(at: part)
            fm.createFile(atPath: part.path, contents: nil)
        }
        progress(pos)
        // Small enough that a cut-off piece wastes little; big enough to keep the link busy.
        let chunk: Int64 = 32 << 20
        var attempt = 0
        while let range = CopyRange.header(from: pos, size: size, chunk: chunk) {
            if await shouldStop() { throw CancellationError() }
            var req = URLRequest(url: OsmoClips.url(path: path, storage: storage))
            req.setValue(range, forHTTPHeaderField: "Range")
            do {
                let (tmp, r) = try await session.download(for: req)
                defer { try? fm.removeItem(at: tmp) }
                guard let h = r as? HTTPURLResponse, h.statusCode == 206 || (h.statusCode == 200 && pos == 0) else {
                    throw Failure.gaveUp("HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                let data = try Data(contentsOf: tmp, options: .alwaysMapped)
                // A 200 means the camera sent the whole file; keep only what we asked for.
                let piece = h.statusCode == 200 ? data.prefix(Int(min(chunk, size))) : data
                guard !piece.isEmpty else { throw Failure.gaveUp("empty reply at \(pos)") }
                let out = try FileHandle(forWritingTo: part)
                try out.seek(toOffset: UInt64(pos))
                try out.write(contentsOf: piece)
                try out.truncate(atOffset: UInt64(pos) + UInt64(piece.count))
                try out.close()
                pos += Int64(piece.count)
                attempt = 0
                progress(pos)
            } catch {
                attempt += 1
                guard policy.shouldRetry(attempt: attempt) else {
                    throw Failure.gaveUp("\(error.localizedDescription) (\(policy.maxAttempts) tries at byte \(pos))")
                }
                let hiccup = Hiccup(attempt: attempt, offset: pos, error: error, wait: policy.delay(attempt: attempt))
                guard await recover(hiccup) else { throw CancellationError() }
                // Wait in short steps so a recording starting mid-wait ends the copy at once.
                let until = Date().addingTimeInterval(hiccup.wait)
                while Date() < until {
                    if await shouldStop() { throw CancellationError() }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        let got = ((try? fm.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard got == size else { throw Failure.sizeMismatch(got, size) }
        // Make sure every byte is on the disk before the file gets its real name, since the
        // camera's copy may be deleted once this returns.
        try fullSync(part)
        try fm.moveItem(at: part, to: dest)
        try fullSync(dest.deletingLastPathComponent())
    }

    /// Flushes a file (or folder entry) all the way to the disk, not just the drive's cache.
    static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure.gaveUp("couldn't open \(url.lastPathComponent) to flush it") }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw Failure.gaveUp("couldn't flush \(url.lastPathComponent) to disk")
        }
    }
}
