import XCTest
@testable import OsmoSyncCore

final class OsmoMediaTests: XCTestCase {
    func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    func pathField(_ s: String, sub: UInt8 = 1) -> [UInt8] {
        let a = Array(s.utf8)
        return [0x1A, UInt8(a.count + 6), 0, 0, 0, sub] + a
    }

    /// A video record in the Pocket 4 Pro shape: size, handle, then `03 FF 19 06` before the path.
    func videoRecord(path: String, handle: UInt32, size: UInt32) -> [UInt8] {
        // size @ marker−14, handle @ marker−10, so 6 bytes sit between handle and marker.
        le(size) + le(handle) + [0, 0, 0, 0, 0x03, 0xFF] + [0x19, 0x06]
            + [0xAA, 0xBB, 0xCC, 0xDD, 0xEE] + pathField(path)
            + pathField("MISC/THM/" + path.suffix(30), sub: 2)
    }

    func testDecodesHandleAndSizePerRecord() {
        let a = "DCIM/DJI_001/DJI_20261113170135_0012_D"
        let b = "DCIM/DJI_001/DJI_20261113170203_0013_D"
        let buf = le(2) + videoRecord(path: a, handle: 0x4010_0140, size: 12_345_678)
            + videoRecord(path: b, handle: 0x4010_0180, size: 4_000_000_000)
        let r = OsmoMedia.records(in: buf)
        XCTAssertEqual(r, [OsmoMediaRecord(path: a, handle: 0x4010_0140, size: 12_345_678),
                           OsmoMediaRecord(path: b, handle: 0x4010_0180, size: 4_000_000_000)])
    }

    func testRecordWithoutMarkerHasNoHandle() {
        let a = "DCIM/DJI_001/DJI_20261113170135_0012_D"
        let r = OsmoMedia.records(in: [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8] + pathField(a))
        XCTAssertEqual(r.first?.handle, 0)
    }

    func testIgnoresThumbnailPaths() {
        let r = OsmoMedia.records(in: pathField("MISC/THM/x", sub: 2) + pathField("DCIM/x", sub: 2))
        XCTAssertTrue(r.isEmpty)
    }

    func testDeleteFrame() {
        let f = DUML.deleteFiles(handles: [0x4010_0140], seq: 3)
        XCTAssertEqual([f.cmdSet, f.cmdID], [0x00, 0x28])
        XCTAssertEqual(f.payload, [0x01, 0x40, 0x01, 0x10, 0x40, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0])
        XCTAssertEqual(DUML.deleteStatus([0x00, 0x00]), 0)
        XCTAssertEqual(DUML.deleteStatus([0xD6, 0x00]), 0xD6)
        XCTAssertNil(DUML.deleteStatus([]))
    }
}

final class DeleteCheckTests: XCTestCase {
    func v(local: Int64? = 1000, served: Int64 = 1000, listed: UInt32 = 1000, handle: UInt32 = 7,
           duration: Double? = 30, expected: Double? = 31) -> DeleteCheck.Verdict {
        DeleteCheck.verdict(localSize: local, servedSize: served, listedSize: listed, handle: handle,
                            duration: duration, expectedDuration: expected)
    }

    func testSafeWhenEverythingMatches() {
        XCTAssertEqual(v(), .safe)
        // Over 4 GiB the list's u32 wraps; the low 32 bits must still match.
        let big: Int64 = 5_000_000_000
        XCTAssertEqual(v(local: big, served: big, listed: UInt32(truncatingIfNeeded: big)), .safe)
    }

    func testKeepsOnAnyDoubt() {
        XCTAssertNotEqual(v(local: nil), .safe)            // file missing
        XCTAssertNotEqual(v(local: 999), .safe)            // partial copy
        XCTAssertNotEqual(v(served: 0), .safe)             // size never known
        XCTAssertNotEqual(v(listed: 0), .safe)             // list gave no size
        XCTAssertNotEqual(v(listed: 1001), .safe)          // list disagrees
        XCTAssertNotEqual(v(handle: 0), .safe)             // no id to delete by
        XCTAssertNotEqual(v(duration: nil), .safe)         // unreadable
        XCTAssertNotEqual(v(duration: 0.1), .safe)         // empty video
        XCTAssertNotEqual(v(duration: 600, expected: 30), .safe)  // not this take's clip
    }
}
