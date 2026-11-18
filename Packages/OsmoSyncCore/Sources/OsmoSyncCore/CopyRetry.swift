import Foundation

/// How a Wi-Fi copy from the camera's hotspot recovers when a piece fails.
///
/// The Pocket can drop the Mac off its hotspot partway through a long copy (seen as a
/// deauth from the camera at full signal), so a retry has to get the Mac back on the
/// hotspot first, and if that fails, ask the camera to bring its hotspot up again.
public struct CopyRetry: Equatable {
    /// Failures in a row before the copy stops. Any progress resets the count.
    public let maxAttempts: Int
    public let firstDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(maxAttempts: Int = 8, firstDelay: TimeInterval = 2, maxDelay: TimeInterval = 60) {
        self.maxAttempts = maxAttempts
        self.firstDelay = firstDelay
        self.maxDelay = maxDelay
    }

    /// Wait before retry `attempt` (1-based): 2, 4, 8, 16, 32, 60, 60… seconds.
    public func delay(attempt: Int) -> TimeInterval {
        let n = max(attempt, 1) - 1
        return min(firstDelay * pow(2, Double(min(n, 30))), maxDelay)
    }

    public func shouldRetry(attempt: Int) -> Bool { attempt <= maxAttempts }

    public enum Step: Equatable {
        /// The Mac is still on the hotspot; just ask again.
        case retry
        /// The Mac fell off the hotspot; join it again.
        case rejoinMac
        /// Joining didn't work last time, or the link looks up but nothing answers: have the
        /// camera restart its hotspot over Bluetooth, then join.
        case restartHotspot
    }

    /// - Parameters:
    ///   - attempt: this retry's number, from 1.
    ///   - macOnHotspot: the Mac's Wi-Fi has a camera-hotspot address right now.
    ///   - rejoinFailedBefore: an earlier rejoin in this run of failures didn't get an address.
    public func step(attempt: Int, macOnHotspot: Bool, rejoinFailedBefore: Bool) -> Step {
        if !macOnHotspot { return rejoinFailedBefore ? .restartHotspot : .rejoinMac }
        // On the hotspot but still failing: the camera's file server may be wedged.
        return attempt >= 3 ? .restartHotspot : .retry
    }
}

/// Byte ranges for a resumable copy. Sizes are 64-bit all the way: clips pass 4 GB.
public enum CopyRange {
    /// The HTTP Range header for the next piece, or nil when the copy is complete.
    public static func header(from pos: Int64, size: Int64, chunk: Int64) -> String? {
        guard pos >= 0, pos < size, chunk > 0 else { return nil }
        return "bytes=\(pos)-\(min(pos + chunk, size) - 1)"
    }

    /// Where to resume from given what's already in the `.part` file. A part file larger
    /// than the clip is from something else and starts over.
    public static func resumePoint(partSize: Int64?, size: Int64) -> Int64 {
        guard let p = partSize, p > 0, p <= size else { return 0 }
        return p
    }
}
