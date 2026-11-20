import Foundation

/// Checks a copied clip against the quality Scott records at (4K, 60 fps).
///
/// While an app streams the Pocket as a webcam, the camera's own recording follows the
/// webcam's format (for example 1080p at 30 fps), whatever its video setting says.
public struct ClipQuality: Equatable {
    public let width: Int
    public let height: Int
    public let fps: Double

    public init(width: Int, height: Int, fps: Double) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    /// The short side, so portrait clips count the same as landscape ones.
    var lines: Int { min(width, height) }

    /// "1920×1080, 30 fps".
    public var summary: String { "\(width)×\(height), \(Int(fps.rounded())) fps" }

    /// Nil when the clip is at least `minLines` tall and `minFPS` fast; otherwise a note
    /// saying what it is and the likely cause.
    public func shortfall(minLines: Int = 2160, minFPS: Double = 50) -> String? {
        guard lines < minLines || fps < minFPS else { return nil }
        return "Recorded at \(summary), not 4K 60. Was Screen Studio using the Osmo as its webcam?"
    }
}
