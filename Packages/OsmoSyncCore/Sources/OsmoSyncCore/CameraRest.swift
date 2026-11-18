import Foundation

/// When OsmoSync lets the Pocket idle between takes.
///
/// While the Wi-Fi command link is open, OsmoSync answers the camera 40 times a second and
/// says "app present" every second, so the camera never idles. Between takes nothing needs
/// that link: it reopens in about a second when a recording starts.
public struct CameraRest {
    /// Quiet time before resting.
    public let after: TimeInterval
    /// How often to check, while resting, that the camera is still on the network.
    public let checkEvery: TimeInterval
    /// Missed checks in a row before waking to reconnect properly.
    public let missesBeforeWake: Int

    public init(after: TimeInterval = 120, checkEvery: TimeInterval = 60, missesBeforeWake: Int = 2) {
        self.after = after
        self.checkEvery = checkEvery
        self.missesBeforeWake = missesBeforeWake
    }

    /// - Parameters:
    ///   - busy: recording, copying, joining Wi-Fi, tracking, or steering the camera.
    ///   - linkHealthy: the link is open and the camera spoke recently. Resting only ever
    ///     closes a working link; a broken one is the watchdog's job.
    public func shouldRest(now: Date, lastActivity: Date, busy: Bool, linkHealthy: Bool) -> Bool {
        !busy && linkHealthy && now.timeIntervalSince(lastActivity) >= after
    }

    public func checkDue(now: Date, lastCheck: Date) -> Bool {
        now.timeIntervalSince(lastCheck) >= checkEvery
    }

    public func shouldWake(misses: Int) -> Bool { misses >= missesBeforeWake }
}
