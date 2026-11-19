import Foundation
import XCTest
@testable import kicklab

final class RFPredictionStorageCleanupTests: XCTestCase {
    func testExplicitCacheClearIncludesPredictionsAndKeepsSavedFiles() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = VideoStorageFiles(historyRoot:root.appendingPathComponent("History"),cacheRoot:root.appendingPathComponent("Caches"),
            temporaryRoot:root.appendingPathComponent("Tmp"),documentsRoot:root.appendingPathComponent("Docs"))
        let kept = files.historyRoot.appendingPathComponent("guest/session.replay.plist")
        try FileManager.default.createDirectory(at:kept.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data([4,5,6]).write(to:kept)
        let database = root.appendingPathComponent("Predictions-v1/predictions.sqlite3")
        try FileManager.default.createDirectory(at:database.deletingLastPathComponent(),withIntermediateDirectories:true)
        for suffix in ["","-wal","-shm"] { try Data([1,2,3]).write(to:URL(fileURLWithPath:database.path+suffix)) }
        XCTAssertEqual(try files.snapshot().cached,9)
        try files.clearCaches()
        XCTAssertEqual(try files.snapshot().cached,0)
        XCTAssertEqual(try Data(contentsOf:kept),Data([4,5,6]))
        for suffix in ["","-wal","-shm"] { XCTAssertFalse(FileManager.default.fileExists(atPath:database.path+suffix)) }
    }
    func testPredictionDirectorySymlinkCannotRedirectCleanup() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let outside = root.appendingPathComponent("Outside/keep.sqlite3")
        try FileManager.default.createDirectory(at:outside.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data([9]).write(to:outside)
        let files = VideoStorageFiles(historyRoot:root.appendingPathComponent("App/History"),cacheRoot:root.appendingPathComponent("App/Caches"),
            temporaryRoot:root.appendingPathComponent("App/Tmp"),documentsRoot:root.appendingPathComponent("App/Docs"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("App"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("App/Predictions-v1"),withDestinationURL:outside.deletingLastPathComponent())
        try files.clearCaches()
        XCTAssertEqual(try Data(contentsOf:outside),Data([9]))
    }
}
