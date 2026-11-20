import XCTest
@testable import OsmoSyncCore

final class ClipQualityTests: XCTestCase {
    func testFourKSixtyPasses() {
        XCTAssertNil(ClipQuality(width: 3840, height: 2160, fps: 59.94).shortfall())
        XCTAssertNil(ClipQuality(width: 2160, height: 3840, fps: 59.94).shortfall())
    }

    func testWebcamFormatsAreFlagged() {
        XCTAssertEqual(ClipQuality(width: 1920, height: 1080, fps: 29.97).shortfall(),
                       "Recorded at 1920×1080, 30 fps, not 4K 60. Was Screen Studio using the Osmo as its webcam?")
        XCTAssertNotNil(ClipQuality(width: 3840, height: 2160, fps: 29.97).shortfall())
        XCTAssertNotNil(ClipQuality(width: 1728, height: 3072, fps: 29.97).shortfall())
    }
}
