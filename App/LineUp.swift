import AVFoundation
import Foundation
import OsmoSyncCore

/// Makes a copy of a camera clip whose t = 0 is the Screen Studio recording's t = 0.
///
/// It matches the clip's sound against Screen Studio's mic recording. If that fails it falls
/// back to the two start times. The original clip is never touched.
enum LineUp {
    struct Outcome {
        /// Where the clip starts on the screen recording's timeline, in seconds.
        let offset: Double
        let method: String
        let confidence: Double?
        let output: URL
    }

    enum Failure: LocalizedError {
        case noProject, noVideo, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noProject: "Screen Studio's project isn't there"
            case .noVideo: "The clip has no video"
            case .exportFailed(let why): "Couldn't write the synced copy: \(why)"
            }
        }
    }

    static let sampleRate = 8000.0
    /// Enough sound for a sure match without holding a long take's audio in memory.
    static let listenSeconds = 180.0

    /// Waits for Screen Studio to finish writing the project, then reads its metadata.
    static func recording(in project: URL, within s: Double = 60) async -> ScreenStudioRecording? {
        let meta = project.appendingPathComponent("recording/metadata.json")
        let deadline = Date().addingTimeInterval(s)
        repeat {
            if let data = try? Data(contentsOf: meta), let r = ScreenStudioRecording(metadata: data) { return r }
            try? await Task.sleep(for: .seconds(2))
        } while Date() < deadline
        return nil
    }

    static func run(clip: URL, project: URL, cameraStart: Date?, log: @escaping (String) -> Void) async throws -> Outcome {
        guard let rec = await recording(in: project) else { throw Failure.noProject }

        var offset: Double?
        var method = "timestamps"
        var confidence: Double?
        let camAudio = try? await monoSamples(clip)
        for file in rec.audioFiles {
            let url = project.appendingPathComponent("recording").appendingPathComponent(file)
            guard let screenAudio = try? await monoSamples(url), let cam = camAudio,
                  let m = AudioSync.offset(reference: screenAudio, other: cam, sampleRate: sampleRate) else { continue }
            log(String(format: "Sound match with %@: %.3f s, confidence %.1f", file, m.seconds, m.confidence))
            if m.confidence >= AudioSync.goodConfidence {
                offset = m.seconds; method = "audio"; confidence = m.confidence
                break
            }
        }
        if offset == nil {
            let start = cameraStart ?? rec.start
            offset = start.timeIntervalSince(rec.start)
            log(String(format: "No clear sound match; using start times: %.3f s", offset!))
        }

        let output = clip.deletingPathExtension().deletingLastPathComponent()
            .appendingPathComponent(clip.deletingPathExtension().lastPathComponent + " (synced).mov")
        try await export(clip, startingAt: offset!, to: output)
        let outcome = Outcome(offset: offset!, method: method, confidence: confidence, output: output)
        writeSidecar(outcome, clip: clip, project: project)
        return outcome
    }

    /// The first few minutes of a file's first audio track, mono, at `sampleRate`.
    static func monoSamples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: listenSeconds, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? Failure.exportFailed("can't read audio") }
        var samples: [Float] = []
        var first = true
        while let buf = out.copyNextSampleBuffer() {
            if first {
                // Audio that starts after t = 0 keeps its place on the timeline.
                let pts = CMSampleBufferGetPresentationTimeStamp(buf).seconds
                if pts.isFinite, pts > 0 { samples += [Float](repeating: 0, count: Int(pts * sampleRate)) }
                first = false
            }
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            let n = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    /// Pads black and silence at the head when the camera started late, trims when it started
    /// early, and re-encodes so the cut lands on the exact frame.
    static func export(_ clip: URL, startingAt offset: Double, to output: URL) async throws {
        let asset = AVURLAsset(url: clip)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        let scale: CMTimeScale = 600_000
        let cut = AudioSync.cut(clipStartsAt: offset)
        let trim = CMTime(seconds: cut.trimHead, preferredTimescale: scale)
        let pad = CMTime(seconds: cut.padHead, preferredTimescale: scale)
        let range = CMTimeRange(start: trim, end: duration)

        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.exportFailed("no video track") }
        try v.insertTimeRange(range, of: video, at: .zero)
        v.preferredTransform = try await video.load(.preferredTransform)
        if pad > .zero { v.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: pad)) }
        if let audio, let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try a.insertTimeRange(range, of: audio, at: .zero)
            if pad > .zero { a.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: pad)) }
        }

        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVCHighestQuality)
        else { throw Failure.exportFailed("no HEVC exporter") }
        session.outputURL = output
        session.outputFileType = .mov
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { k.resume() }
        }
        guard session.status == .completed else {
            throw Failure.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
        }
    }

    static func writeSidecar(_ o: Outcome, clip: URL, project: URL) {
        var info: [String: Any] = [
            "offsetSeconds": (o.offset * 1000).rounded() / 1000,
            "meaning": "Seconds into the Screen Studio recording where the camera clip starts. Positive: the camera started late, so the synced copy begins with black. Negative: it started early, so the head was trimmed.",
            "method": o.method,
            "screenStudioProject": project.lastPathComponent,
            "original": clip.lastPathComponent,
            "synced": o.output.lastPathComponent,
        ]
        if let c = o.confidence { info["confidence"] = (c * 10).rounded() / 10 }
        let url = o.output.deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}
