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
///
/// While recording, Screen Studio keeps the project in its "Recordings In Progress" folder and
/// moves it to the projects folder only after it stops. So both folders are watched, and a
/// project keeps its read position when it moves (same folder name), so no event fires twice.
public final class ScreenStudioLogTailer {
    /// Where Screen Studio 3.x keeps a project while it records.
    public static let inProgressFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Screen Studio/Screen Studio Recordings In Progress")

    public let folders: [URL]
    private var currentName: String?
    private var offset: UInt64 = 0
    private var partial = ""
    private let startedAt: Date

    public init(folders: [URL], now: Date = Date()) {
        self.folders = folders
        self.startedAt = now
    }

    public convenience init(projectsFolder: URL, now: Date = Date()) {
        self.init(folders: [Self.inProgressFolder, projectsFolder], now: now)
    }

    public struct Hit: Equatable {
        public let event: ScreenStudioEvent
        public let time: Date?
        public let project: URL
    }

    public func poll() -> [Hit] {
        guard let (project, log, born) = newestProject() else { return [] }
        // The folder gains ".screenstudio" when it moves; the name before it stays the same.
        let name = project.deletingPathExtension().lastPathComponent
        if name != currentName {
            // Ignore projects begun before the app started, so old recordings never fire events.
            guard born >= startedAt.addingTimeInterval(-5) else { return [] }
            currentName = name
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
            ScreenStudioLog.event(in: line).map { Hit(event: $0, time: ScreenStudioLog.timestamp(of: line), project: project) }
        }
    }

    /// The project whose recording began last, across all watched folders, with its log.
    ///
    /// While recording, Screen Studio 4 keeps a plain folder (`<name>/polyrecorder.log`) in the
    /// in-progress folder. After the stop it becomes `<name>.screenstudio/recording/polyrecorder.log`.
    /// Projects are dated by the log, which is made when recording starts.
    private func newestProject() -> (URL, URL, Date)? {
        let fm = FileManager.default
        var best: (URL, URL, Date)?
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for p in items {
                let candidates = [p.appendingPathComponent("recording/polyrecorder.log"),
                                  p.appendingPathComponent("polyrecorder.log")]
                guard let log = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
                      let born = try? log.resourceValues(forKeys: [.creationDateKey]).creationDate else { continue }
                if best == nil || born > best!.2 { best = (p, log, born) }
            }
        }
        return best
    }
}
