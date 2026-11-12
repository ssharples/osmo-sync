import Foundation

/// Reads Screen Studio's recorder log (`<project>.screenstudio/recording/polyrecorder.log`).
///
/// Screen Studio 3.x writes one project folder per recording under `~/Screen Studio Projects`,
/// and its recorder logs plain lines such as:
/// ```
/// 2026-10-23T17:45:52.110+0100 debug    [Conductor] Starting recording.
/// 2026-10-23T17:45:54.546+0100 notice   [Conductor] Recording resumed. recordFrom=…
/// 2026-10-23T17:48:38.683+0100 warning  [Conductor] Pausing the recording to be able to stop.
/// 2026-10-23T17:48:39.772+0100 notice   [Conductor] Recording stopped. errorCount=0 …
/// ```
/// "Starting recording" comes about two seconds before frames are captured (the countdown),
/// which gives the camera time to spin up.
public enum ScreenStudioEvent: Equatable {
    case starting      // Screen Studio began a recording (countdown)
    case stopping      // the user pressed stop; capture is ending
    case stopped       // recording finished and files are written
}

public enum ScreenStudioLog {
    public static func event(in line: String) -> ScreenStudioEvent? {
        guard line.contains("[Conductor]") else { return nil }
        if line.contains("Starting recording.") { return .starting }
        if line.contains("Pausing the recording to be able to stop") || line.contains("Stopping recording.") { return .stopping }
        if line.contains("Recording stopped.") { return .stopped }
        return nil
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The timestamp at the start of a log line, e.g. `2026-10-23T17:45:52.110+0100`.
    public static func timestamp(of line: String) -> Date? {
        guard let token = line.split(separator: " ", maxSplits: 1).first else { return nil }
        // ISO8601DateFormatter wants "+01:00"; the log writes "+0100".
        var s = String(token)
        if s.count > 5, let sign = s.dropLast(4).last, sign == "+" || sign == "-" {
            s.insert(":", at: s.index(s.endIndex, offsetBy: -2))
        }
        return stampFormatter.date(from: s)
    }
}

/// Follows the newest Screen Studio project's log and reports recording start and stop.
/// Call `poll()` on a timer; it reads only the bytes added since the last call.
public final class ScreenStudioLogTailer {
    public let projectsFolder: URL
    private var currentLog: URL?
    private var offset: UInt64 = 0
    private var partial = ""
    private let startedAt: Date

    public init(projectsFolder: URL, now: Date = Date()) {
        self.projectsFolder = projectsFolder
        self.startedAt = now
    }

    /// The project folder of the log being followed.
    public var currentProject: URL? { currentLog?.deletingLastPathComponent().deletingLastPathComponent() }

    public struct Hit: Equatable {
        public let event: ScreenStudioEvent
        public let time: Date?
        public let project: URL
    }

    public func poll() -> [Hit] {
        let fm = FileManager.default
        guard let newest = newestProject() else { return [] }
        let log = newest.appendingPathComponent("recording/polyrecorder.log")
        if log != currentLog {
            // Ignore projects made before the app started, so old recordings never fire events.
            let created = (try? newest.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard created >= startedAt.addingTimeInterval(-5) else { return [] }
            guard fm.fileExists(atPath: log.path) else { return [] }
            currentLog = log
            offset = 0
            partial = ""
        }
        guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset { offset = 0; partial = "" }   // file was replaced
        guard end > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        let text = partial + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        partial = lines.removeLast()
        return lines.compactMap { line in
            ScreenStudioLog.event(in: line).map { Hit(event: $0, time: ScreenStudioLog.timestamp(of: line), project: newest) }
        }
    }

    private func newestProject() -> URL? {
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: projectsFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        return items
            .filter { $0.pathExtension == "screenstudio" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
    }
}
