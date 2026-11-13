import Foundation

/// Decides when to put the camera back on Wi-Fi. The Pocket drops off the home network when it
/// powers off or sleeps, yet Bluetooth comes back on its own; without this, record commands
/// have nowhere to go until someone reconnects by hand.
public struct WiFiWatchdog {
    public enum Action: Equatable { case wait, rejoin }

    /// How long the link must be down before trying.
    public var grace: TimeInterval
    /// Gap between tries, doubling after each failure up to `maxGap`.
    public var firstGap: TimeInterval
    public var maxGap: TimeInterval

    public private(set) var downSince: Date?
    private var lastTry: Date?
    private var gap: TimeInterval

    public init(grace: TimeInterval = 15, firstGap: TimeInterval = 30, maxGap: TimeInterval = 300) {
        self.grace = grace
        self.firstGap = firstGap
        self.maxGap = maxGap
        gap = firstGap
    }

    /// - Parameters:
    ///   - bleReady: the camera is connected over Bluetooth (needed to send the join).
    ///   - linkHealthy: the Wi-Fi command link is open and the camera spoke recently.
    ///   - held: something else owns the camera's Wi-Fi right now (a hotspot copy, a join).
    public mutating func check(now: Date, bleReady: Bool, linkHealthy: Bool, held: Bool) -> Action {
        if linkHealthy || !bleReady {
            reset()
            return .wait
        }
        if held {
            downSince = nil
            return .wait
        }
        guard let since = downSince else {
            downSince = now
            return .wait
        }
        guard now.timeIntervalSince(since) >= grace else { return .wait }
        if let last = lastTry {
            guard now.timeIntervalSince(last) >= gap else { return .wait }
            gap = min(gap * 2, maxGap)
        }
        lastTry = now
        return .rejoin
    }

    /// Start over, for example after Bluetooth reconnects or the link comes back.
    public mutating func reset() {
        downSince = nil
        lastTry = nil
        gap = firstGap
    }
}
