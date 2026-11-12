import Accelerate
import Foundation

/// Lines up two recordings of the same sound with GCC-PHAT cross-correlation.
///
/// Both signals are mono at the same sample rate. The cross-spectrum A·conj(B) is divided by
/// its own magnitude, so only phase is left, which gives one sharp peak at the true lag even
/// with different mics, levels and room echo.
public enum AudioSync {
    public struct Match: Equatable {
        /// Where `other`'s t = 0 falls on `reference`'s timeline, in seconds.
        /// Positive: `other` started later. Negative: it started earlier.
        public let seconds: Double
        /// Peak height over the correlation's standard deviation. Above 8 is a solid match.
        public let confidence: Double
    }

    public static let goodConfidence = 8.0

    /// Finds where `other` starts on `reference`'s timeline, searching lags up to `maxLag`
    /// seconds either way. Nil when either signal is silent or too short.
    public static func offset(reference a: [Float], other b: [Float], sampleRate: Double,
                              maxLag: Double = 60) -> Match? {
        guard a.count > 256, b.count > 256, rms(a) > 1e-5, rms(b) > 1e-5 else { return nil }
        var n = 8
        while n < a.count + b.count { n <<= 1 }
        guard let fwd = try? vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .forward,
                                                            transformType: .complexComplex, ofType: Float.self),
              let inv = try? vDSP.DiscreteFourierTransform(previous: fwd, count: n, direction: .inverse,
                                                           transformType: .complexComplex, ofType: Float.self)
        else { return nil }

        let zeros = [Float](repeating: 0, count: n)
        func spectrum(_ x: [Float]) -> ([Float], [Float]) {
            var re = centred(x) + [Float](repeating: 0, count: n - x.count)
            var outRe = zeros, outIm = zeros
            fwd.transform(inputReal: re, inputImaginary: zeros, outputReal: &outRe, outputImaginary: &outIm)
            re = []
            return (outRe, outIm)
        }
        let (ar, ai) = spectrum(a)
        let (br, bi) = spectrum(b)

        // X = A · conj(B), then keep only the phase.
        var xr = zeros, xi = zeros
        for k in 0..<n {
            let r = ar[k] * br[k] + ai[k] * bi[k]
            let i = ai[k] * br[k] - ar[k] * bi[k]
            let m = (r * r + i * i).squareRoot() + 1e-12
            xr[k] = r / m
            xi[k] = i / m
        }
        var cr = zeros, ci = zeros
        inv.transform(inputReal: xr, inputImaginary: xi, outputReal: &cr, outputImaginary: &ci)

        // c[k] peaks where a[t + k] matches b[t]: b's start sits k samples into a.
        // Negative lags wrap round to the end of the buffer.
        let reach = min(Int(maxLag * sampleRate), n / 2 - 1)
        var best = 0, peak = -Float.infinity
        for k in 0...reach where cr[k] > peak { peak = cr[k]; best = k }
        for k in max(n - reach, reach + 1)..<n where cr[k] > peak { peak = cr[k]; best = k - n }

        let sd = standardDeviation(cr)
        guard sd > 0 else { return nil }
        return Match(seconds: Double(best) / sampleRate, confidence: Double(peak / sd))
    }

    /// How to cut a clip so its t = 0 lands on the reference's t = 0, given where the clip
    /// starts on the reference timeline (`AudioSync.Match.seconds`).
    public static func cut(clipStartsAt offset: Double) -> (padHead: Double, trimHead: Double) {
        offset >= 0 ? (offset, 0) : (0, -offset)
    }

    static func rms(_ x: [Float]) -> Float { vDSP.rootMeanSquare(x) }

    static func centred(_ x: [Float]) -> [Float] { vDSP.add(-vDSP.mean(x), x) }

    static func standardDeviation(_ x: [Float]) -> Float {
        let m = vDSP.mean(x)
        let sq = vDSP.meanSquare(x)
        return max(sq - m * m, 0).squareRoot()
    }
}

/// What a finished Screen Studio project says about its recording (`recording/metadata.json`).
public struct ScreenStudioRecording: Equatable {
    /// When the screen recording's first frame was captured: the project's t = 0.
    public let start: Date
    /// Audio files Screen Studio recorded (microphone first, then system audio), relative to `recording/`.
    public let audioFiles: [String]

    public init(start: Date, audioFiles: [String]) {
        self.start = start
        self.audioFiles = audioFiles
    }

    public init?(metadata data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recorders = root["recorders"] as? [[String: Any]] else { return nil }
        var display: Double?, earliest: Double?
        var mic: [String] = [], system: [String] = []
        for r in recorders {
            let id = (r["id"] as? String ?? "").lowercased()
            let sessions = r["sessions"] as? [[String: Any]] ?? []
            for s in sessions {
                if let ms = s["unixStartMs"] as? Double {
                    earliest = min(earliest ?? ms, ms)
                    if id.contains("display") || id.contains("window") { display = display ?? ms }
                }
                guard let file = s["outputFilename"] as? String else { continue }
                if id.contains("microphone") { mic.append(file) }
                else if id.contains("system") || id.contains("audio") { system.append(file) }
            }
        }
        guard let ms = display ?? earliest else { return nil }
        self.init(start: Date(timeIntervalSince1970: ms / 1000), audioFiles: mic + system)
    }
}
