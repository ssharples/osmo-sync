import Foundation

/// Telling an Osmo Pocket apart from other DJI gear on USB.
public enum PocketUSB {
    public static let djiVendorID = 0x2CA3

    /// DJI's wireless mic receivers share the vendor id, so the product name decides.
    public static func isPocket(vendorID: Int, productName: String?) -> Bool {
        guard vendorID == djiVendorID, let n = productName else { return false }
        return n.localizedCaseInsensitiveContains("pocket") || n.localizedCaseInsensitiveContains("osmo")
    }
}

/// Decides what to do to get the Pocket connected: on a nudge (USB plug-in, Mac wake) or
/// on the regular check that catches the camera powering on nearby.
public struct AutoConnect {
    public enum Link: Equatable {
        /// No Bluetooth link and no connection attempt.
        case off
        /// Attempt failed (no approval, camera busy, out of range).
        case failed
        /// A connection is pending, since this time.
        case connecting(since: Date)
        /// The camera is asking you to tap OK.
        case approving
        case ready
    }

    public enum Action: Equatable {
        case none
        /// Start a Bluetooth connection to the saved camera (or find one).
        case connect
        /// Drop a stuck attempt and start again.
        case restart
        /// Bluetooth is up; put the camera on the home Wi-Fi now.
        case rejoinWiFi
    }

    /// Waits after a failed attempt before the regular check tries again, so a camera nobody
    /// is answering doesn't ask for approval over and over.
    public let firstGap: TimeInterval
    public let maxGap: TimeInterval
    /// How long a pending connection may sit before a nudge restarts it.
    public let stuckAfter: TimeInterval
    private var failures = 0
    private var nextTry = Date.distantPast

    public init(firstGap: TimeInterval = 20, maxGap: TimeInterval = 300, stuckAfter: TimeInterval = 20) {
        self.firstGap = firstGap
        self.maxGap = maxGap
        self.stuckAfter = stuckAfter
    }

    /// - Parameters:
    ///   - nudged: true for USB plug-in, Mac wake, or camera seen nearby. These act at once.
    ///   - userStopped: you pressed Disconnect. Only a nudge overrides that.
    public mutating func next(link: Link, wifiHealthy: Bool, wifiSetUp: Bool, nudged: Bool,
                              userStopped: Bool, now: Date) -> Action {
        switch link {
        case .ready:
            failures = 0
            nextTry = .distantPast
            return nudged && wifiSetUp && !wifiHealthy ? .rejoinWiFi : .none
        case .approving:
            return .none
        case .connecting(let since):
            return nudged && now.timeIntervalSince(since) > stuckAfter ? .restart : .none
        case .off, .failed:
            if nudged {
                nextTry = .distantPast
                return .connect
            }
            if userStopped || now < nextTry { return .none }
            if link == .failed {
                let gap = min(firstGap * pow(2, Double(failures)), maxGap)
                failures += 1
                nextTry = now.addingTimeInterval(gap)
            }
            return .connect
        }
    }
}
