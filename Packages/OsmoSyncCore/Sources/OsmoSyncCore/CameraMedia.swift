import Foundation

/// Finds the Osmo clips that belong to a take on a mounted camera card.
public enum CameraMedia {
    public static let videoExtensions: Set<String> = ["mp4", "mov"]

    /// True when the volume looks like a DJI camera card (`DCIM/DJI_001`, `DCIM/100MEDIA`, …).
    public static func isCameraVolume(_ root: URL) -> Bool {
        let dcim = root.appendingPathComponent("DCIM")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: dcim.path) else { return false }
        return !dirs.isEmpty
    }

    /// All video files under DCIM, newest first.
    public static func videos(on root: URL) -> [(url: URL, modified: Date, size: Int)] {
        let dcim = root.appendingPathComponent("DCIM")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Date, Int)] = []
        for case let url as URL in walker where videoExtensions.contains(url.pathExtension.lowercased()) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append((url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0))
        }
        return out.sorted { $0.1 > $1.1 }.map { (url: $0.0, modified: $0.1, size: $0.2) }
    }

    /// Picks the clips written during a take. A clip's modification time is when the camera
    /// finished writing it, so it falls between the take's start and a little after its end.
    /// Long takes split into several files; all of them match.
    public static func clips(_ files: [(url: URL, modified: Date, size: Int)],
                             takeStart: Date, takeEnd: Date, slack: TimeInterval = 120) -> [URL] {
        files.filter { $0.modified >= takeStart.addingTimeInterval(-5) && $0.modified <= takeEnd.addingTimeInterval(slack) }
            .sorted { $0.modified < $1.modified }
            .map(\.url)
    }
}
