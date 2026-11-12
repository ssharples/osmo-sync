import Foundation

/// Finding a take's clips on the camera, and fetching them from the camera's own hotspot.
///
/// The camera serves files only on its hotspot (`192.168.2.1`), over plain HTTP:
/// `GET /v2?storage={0|1}&path=<path>.MP4`, with HEAD for the size and Range for resume.
/// Route as used by OsmoOffload (MIT), tested there on a Pocket 4 Pro.
public enum OsmoClips {
    public static let hotspotHost = "192.168.2.1"

    /// Clip paths, without extension, in a media list's data bytes,
    /// e.g. `DCIM/DJI_001/DJI_20261112205846_0005_D`. Newest first, no repeats.
    public static func paths(in data: [UInt8]) -> [String] {
        let text = String(decoding: data.map { (0x20...0x7E).contains($0) ? $0 : 0x0A }, as: UTF8.self)
        let pattern = try! NSRegularExpression(pattern: #"DCIM/[A-Za-z0-9_]+/DJI_\d{14}_\d{4}(?:_[A-Z])?"#)
        var seen = Set<String>()
        let found = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            let p = String(text[r])
            return seen.insert(p).inserted ? p : nil
        }
        return found.sorted { (date(of: $0) ?? .distantPast) > (date(of: $1) ?? .distantPast) }
    }

    /// The start time in a clip's name (`DJI_YYYYMMDDHHMMSS_…`), read in the camera's time zone.
    public static func date(of path: String, timeZone: TimeZone = .current) -> Date? {
        guard let r = path.range(of: #"DJI_\d{14}"#, options: .regularExpression) else { return nil }
        let digits = path[r].dropFirst(4)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(digits))
    }

    /// The clips that belong to a take: started between just before the take and its end.
    /// If none fit (the camera's clock can drift), the newest clip within ten minutes.
    public static func pick(_ paths: [String], takeStart: Date, takeEnd: Date, timeZone: TimeZone = .current) -> [String] {
        let dated = paths.compactMap { p in date(of: p, timeZone: timeZone).map { (p, $0) } }
        let inside = dated.filter { $0.1 >= takeStart.addingTimeInterval(-30) && $0.1 <= takeEnd.addingTimeInterval(10) }
        if !inside.isEmpty { return inside.sorted { $0.1 < $1.1 }.map(\.0) }
        let near = dated.filter { $0.1 >= takeStart.addingTimeInterval(-600) && $0.1 <= takeEnd.addingTimeInterval(600) }
        return near.max { $0.1 < $1.1 }.map { [$0.0] } ?? []
    }

    /// Reads a `[status][len][bytes…]` reply, as `0x07/0x07` and `0x07/0x0E` send.
    public static func packedString(_ payload: [UInt8]) -> String? {
        guard payload.count >= 2, payload[0] == 0 else { return nil }
        let n = Int(payload[1])
        guard n > 0, payload.count >= 2 + n else { return nil }
        return String(decoding: payload[2..<2 + n], as: UTF8.self)
    }

    /// The file URL on the camera's hotspot. Storage 1 is internal, 0 the microSD card.
    public static func url(path: String, storage: Int, ext: String = "MP4", host: String = hotspotHost) -> URL {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.path = "/v2"
        c.queryItems = [URLQueryItem(name: "storage", value: String(storage)),
                        URLQueryItem(name: "path", value: "\(path).\(ext)")]
        return c.url!
    }
}
