import Foundation

/// One file in the camera's media list, with the handle the camera deletes it by.
public struct OsmoMediaRecord: Equatable {
    /// `DCIM/<folder>/<base>`, no extension.
    public var path: String
    /// The camera's id for this file. Zero when the list didn't carry one.
    public var handle: UInt32
    /// Byte size, as a u32: files over 4 GiB wrap.
    public var size: UInt32

    public init(path: String, handle: UInt32, size: UInt32) {
        self.path = path
        self.handle = handle
        self.size = size
    }
}

public enum OsmoMedia {
    /// Decodes a reassembled media list (the `0x00/0x27` data chunks with their 10-byte
    /// sub-headers stripped). Each record is anchored on its media path field,
    /// `1A <len> 00 00 00 01 "DCIM/…"`. The handle and size sit before it, at fixed offsets
    /// from a `[FE|FF] 19 06` marker. Layout from OsmoOffload (MIT), checked there on a
    /// Pocket 4 Pro.
    public static func records(in buf: [UInt8]) -> [OsmoMediaRecord] {
        var paths: [(start: Int, end: Int, path: String)] = []
        var i = 0
        while i < buf.count {
            if let (path, end) = readPath(buf, at: i) {
                paths.append((i, end, path))
                i = end
            } else {
                i += 1
            }
        }
        var out: [OsmoMediaRecord] = []
        var seen = Set<String>()
        for (k, p) in paths.enumerated() {
            let lo = k > 0 ? paths[k - 1].end : 0
            var handle: UInt32 = 0
            var size: UInt32 = 0
            var found = false
            var j = max(lo, 1)
            while j < p.start - 1 {
                if buf[j] == 0x19, buf[j + 1] == 0x06, buf[j - 1] == 0xFE || buf[j - 1] == 0xFF {
                    if j >= 10 { handle = u32(buf, j - 10) }
                    if j >= 14 { size = u32(buf, j - 14) }
                    found = true
                    break
                }
                j += 1
            }
            if !found {
                // Some bodies write the `19 06` pair 7 bytes before the path field, unprefixed.
                let q = p.start - 7
                if q >= 14, buf[q] == 0x19, buf[q + 1] == 0x06 {
                    handle = u32(buf, q - 10)
                    size = u32(buf, q - 14)
                }
            }
            guard seen.insert(p.path).inserted else { continue }
            out.append(OsmoMediaRecord(path: p.path, handle: handle, size: size))
        }
        return out
    }

    private static func readPath(_ b: [UInt8], at i: Int) -> (String, Int)? {
        guard i + 6 <= b.count, b[i] == 0x1A, b[i + 2] == 0, b[i + 3] == 0, b[i + 4] == 0, b[i + 5] == 0x01 else { return nil }
        let n = Int(b[i + 1]) - 6
        guard n >= 5, i + 6 + n <= b.count else { return nil }
        let bytes = b[(i + 6)..<(i + 6 + n)]
        guard bytes.starts(with: Array("DCIM/".utf8)), bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return (String(decoding: bytes, as: UTF8.self), i + 6 + n)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// The checks a copied clip must pass before OsmoSync deletes the camera's original.
public enum DeleteCheck {
    public enum Verdict: Equatable {
        case safe
        case keep(String)
    }

    /// - Parameters:
    ///   - localSize: bytes of the finished file in Osmo Takes, or nil if it isn't there.
    ///   - servedSize: the size the camera served the file at (HTTP HEAD), which the copy used.
    ///   - listedSize: the size in the camera's media list (u32, so it wraps over 4 GiB).
    ///   - handle: the camera's handle for the file; zero means unknown.
    ///   - duration: seconds of video the Mac could read from the copy, or nil if unreadable.
    ///   - expectedDuration: the take's length, when known; the clip should be close to it.
    public static func verdict(localSize: Int64?, servedSize: Int64, listedSize: UInt32, handle: UInt32,
                               duration: Double?, expectedDuration: Double?) -> Verdict {
        guard let local = localSize else { return .keep("the copy isn't in the folder") }
        guard servedSize > 0, local == servedSize else { return .keep("the copy is \(local) bytes, the camera's file \(servedSize)") }
        guard listedSize != 0, UInt32(truncatingIfNeeded: local) == listedSize else {
            return .keep("the camera's list gives a different size")
        }
        guard handle != 0 else { return .keep("the camera's list gave no file id") }
        guard let d = duration, d >= 0.5 else { return .keep("the Mac couldn't read the copy as video") }
        if let want = expectedDuration, want > 0, d > want + 60 {
            return .keep(String(format: "the copy runs %.0fs but the take was %.0fs", d, want))
        }
        return .safe
    }
}
