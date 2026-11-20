import XCTest
@testable import OsmoSyncCore

final class CopyCheckedTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testCopiesAndKeepsAMatchingCopy() throws {
        let src = dir.appendingPathComponent("a.MP4"), dst = dir.appendingPathComponent("b.MP4")
        try Data(repeating: 7, count: 4096).write(to: src)
        try CameraMedia.copyChecked(src, to: dst)
        XCTAssertEqual(try Data(contentsOf: dst).count, 4096)
    }

    func testLeavesNothingBehindWhenTheCopyFails() {
        let src = dir.appendingPathComponent("missing.MP4"), dst = dir.appendingPathComponent("b.MP4")
        XCTAssertThrowsError(try CameraMedia.copyChecked(src, to: dst))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path))
    }
}
