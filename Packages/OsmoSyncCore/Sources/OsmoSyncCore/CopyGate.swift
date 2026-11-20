import Foundation

/// When an automatic Wi-Fi copy may start.
///
/// Copies start as soon as a take stops. They hold back only while the camera records, and
/// for a few minutes after the camera reports it's hot, since running the hotspot flat out
/// then can tip it into its overheating warning.
public struct CopyGate {
    /// How long to wait after the camera's heat flag was last seen on.
    public let heatWait: TimeInterval

    public init(heatWait: TimeInterval = 300) {
        self.heatWait = heatWait
    }

    public enum Verdict: Equatable {
        case go
        case wait(String)
    }

    /// When the heat wait ends, or nil if the camera hasn't reported heat.
    public func coolsAt(lastHot: Date?) -> Date? {
        lastHot?.addingTimeInterval(heatWait)
    }

    /// - Parameter lastHot: the last time the camera's heat flag was seen on.
    public func check(now: Date, recording: Bool, lastHot: Date?) -> Verdict {
        if recording { return .wait("the camera is recording") }
        if let hot = lastHot, now.timeIntervalSince(hot) < heatWait {
            return .wait("the camera reported it's hot")
        }
        return .go
    }
}
