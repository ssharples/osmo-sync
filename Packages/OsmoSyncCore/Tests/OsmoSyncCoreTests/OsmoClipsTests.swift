import XCTest
@testable import OsmoSyncCore

final class OsmoClipsTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testPathsFromListBytes() {
        var data: [UInt8] = [0x01, 0x00, 0x0d]
        data += Array("DCIM/DJI_001/DJI_20261112204150_0004_D".utf8) + [0x00, 0x12]
        data += Array("DCIM/DJI_001/DJI_20261112205846_0005_D".utf8) + [0x00]
        data += Array("MISC/THM/DJI_001/DJI_20261112205846_0005_D.scr".utf8) + [0x00]
        XCTAssertEqual(OsmoClips.paths(in: data),
                       ["DCIM/DJI_001/DJI_20261112205846_0005_D", "DCIM/DJI_001/DJI_20261112204150_0004_D"])
    }

    func testPickClipInsideTheTake() {
        let paths = ["DCIM/DJI_001/DJI_20261112205846_0005_D", "DCIM/DJI_001/DJI_20261112204150_0004_D"]
        let start = OsmoClips.date(of: "DJI_20261112205846", timeZone: utc)!
        let picked = OsmoClips.pick(paths, takeStart: start.addingTimeInterval(-1), takeEnd: start.addingTimeInterval(19), timeZone: utc)
        XCTAssertEqual(picked, ["DCIM/DJI_001/DJI_20261112205846_0005_D"])
    }

    func testPickFallsBackToNewestNearbyWhenClockDrifts() {
        let paths = ["DCIM/DJI_001/DJI_20261112205546_0005_D", "DCIM/DJI_001/DJI_20261112100000_0001_D"]
        let start = OsmoClips.date(of: "DJI_20261112205846", timeZone: utc)!
        XCTAssertEqual(OsmoClips.pick(paths, takeStart: start, takeEnd: start.addingTimeInterval(20), timeZone: utc),
                       ["DCIM/DJI_001/DJI_20261112205546_0005_D"])
        XCTAssertEqual(OsmoClips.pick(["DCIM/DJI_001/DJI_20261112100000_0001_D"], takeStart: start,
                                      takeEnd: start.addingTimeInterval(20), timeZone: utc), [])
    }

    func testPackedStringReply() {
        XCTAssertEqual(OsmoClips.packedString([0, 4] + Array("OSMO".utf8)), "OSMO")
        XCTAssertNil(OsmoClips.packedString([1, 4] + Array("OSMO".utf8)))
        XCTAssertNil(OsmoClips.packedString([0, 9, 0x41]))
    }

    func testHotspotURL() {
        XCTAssertEqual(OsmoClips.url(path: "DCIM/DJI_001/DJI_20261112205846_0005_D", storage: 1).absoluteString,
                       "http://192.168.2.1/v2?storage=1&path=DCIM/DJI_001/DJI_20261112205846_0005_D.MP4")
    }
}
