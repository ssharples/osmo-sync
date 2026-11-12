import XCTest
@testable import OsmoSyncCore

final class AudioSyncTests: XCTestCase {
    let rate = 8000.0

    /// Repeatable noise so the tests don't depend on luck.
    func noise(_ count: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<count).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: s >> 11) % 2000) / 1000 - 1
        }
    }

    func testCameraStartedLate() throws {
        // The camera's clip begins 1.25 s into the reference.
        let screen = noise(20 * 8000, seed: 1)
        let lag = Int(1.25 * rate)
        let hiss = noise(screen.count - lag, seed: 9)
        let camera = (lag..<screen.count).map { i in 0.6 * screen[i] + 0.2 * hiss[i - lag] }
        let m = try XCTUnwrap(AudioSync.offset(reference: screen, other: camera, sampleRate: rate))
        XCTAssertEqual(m.seconds, 1.25, accuracy: 0.001)
        XCTAssertGreaterThan(m.confidence, AudioSync.goodConfidence)
        XCTAssertEqual(AudioSync.cut(clipStartsAt: m.seconds).padHead, 1.25, accuracy: 0.001)
    }

    func testCameraStartedEarly() throws {
        // The camera has 0.8 s of its own sound before the reference begins.
        let screen = noise(20 * 8000, seed: 2)
        let lead = noise(Int(0.8 * rate), seed: 3)
        let camera = lead + screen.map { $0 * 0.5 }
        let m = try XCTUnwrap(AudioSync.offset(reference: screen, other: camera, sampleRate: rate))
        XCTAssertEqual(m.seconds, -0.8, accuracy: 0.001)
        XCTAssertGreaterThan(m.confidence, AudioSync.goodConfidence)
        XCTAssertEqual(AudioSync.cut(clipStartsAt: m.seconds).trimHead, 0.8, accuracy: 0.001)
    }

    func testUnrelatedSoundHasLowConfidence() throws {
        let m = try XCTUnwrap(AudioSync.offset(reference: noise(10 * 8000, seed: 4),
                                               other: noise(10 * 8000, seed: 5), sampleRate: rate))
        XCTAssertLessThan(m.confidence, AudioSync.goodConfidence)
    }

    func testSilenceGivesNoMatch() {
        XCTAssertNil(AudioSync.offset(reference: [Float](repeating: 0, count: 8000),
                                      other: noise(8000, seed: 6), sampleRate: rate))
    }

    func testReadsScreenStudioMetadata() throws {
        let json = """
        {"recorders":[
          {"id":"channel-0-input","sessions":[{"unixStartMs":1794517128000.0}]},
          {"id":"channel-1-display","sessions":[{"outputFilename":"channel-1-display-0.m3u8","unixStartMs":1794517128022.105}]},
          {"id":"channel-2-microphone","sessions":[{"outputFilename":"channel-2-microphone-0.m4a","unixStartMs":1794517128022.105}]}
        ]}
        """
        let r = try XCTUnwrap(ScreenStudioRecording(metadata: Data(json.utf8)))
        XCTAssertEqual(r.start.timeIntervalSince1970, 1794517128.022105, accuracy: 0.0001)
        XCTAssertEqual(r.audioFiles, ["channel-2-microphone-0.m4a"])
    }
}
