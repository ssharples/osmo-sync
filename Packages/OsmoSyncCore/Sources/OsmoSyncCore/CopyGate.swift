import Foundation

/// When an automatic Wi-Fi copy may start.
///
/// A copy runs the camera's own hotspot flat out for a minute or more. Straight after a
/// recording, or while an app streams the camera as a webcam, that extra load is what tips
/// the Pocket into its overheating warning. So automatic copies wait for the camera to cool.
public struct CopyGate {
    /// Rest after a recording ends before copying.
    public let coolDown: TimeInterval
    /// Longest wait for the webcam stream to stop; after this the copy goes ahead anyway,
    /// so a camera preview left open all day doesn't stall copies for good.
    public let maxWebcamWait: TimeInterval

    public init(coolDown: TimeInterval = 300, maxWebcamWait: TimeInterval = 3600) {
        self.coolDown = coolDown
        self.maxWebcamWait = maxWebcamWait
    }

    public enum Verdict: Equatable {
        case go
        case wait(String)
    }

    /// - Parameters:
    ///   - waitingSince: when this copy was first held back.
    ///   - lastHot: the last time the camera's heat flag was seen on.
    public func check(now: Date, waitingSince: Date, recording: Bool, lastRecordingEnded: Date?,
                      webcamInUse: Bool, lastHot: Date?) -> Verdict {
        if recording { return .wait("the camera is recording") }
        if let hot = lastHot, now.timeIntervalSince(hot) < coolDown {
            return .wait("the camera reported it's hot")
        }
        if let ended = lastRecordingEnded, now.timeIntervalSince(ended) < coolDown {
            return .wait("the camera is cooling after recording")
        }
        if webcamInUse, now.timeIntervalSince(waitingSince) < maxWebcamWait {
            return .wait("an app is using the camera as a webcam")
        }
        return .go
    }
}
