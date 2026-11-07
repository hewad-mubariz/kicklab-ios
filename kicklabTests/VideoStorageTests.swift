import XCTest
@testable import kicklab

@MainActor
final class VideoStorageTests: XCTestCase {
    private var root: URL!
    private var library: SessionHistoryLibrary!
    private var files: VideoStorageFiles!
    override func setUp() {
        root = URL.temporaryDirectory.appendingPathComponent("StorageTests-" + UUID().uuidString)
        library = SessionHistoryLibrary(root: root.appendingPathComponent("History"))
        files = VideoStorageFiles(library: library)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func write(_ url: URL, _ data: Data = Data([1, 2, 3])) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func item(owner: UUID? = nil) -> HistorySession {
        HistorySession(id: UUID(), ownerID: owner, touches: 8, durationMS: 2000, source: .gallery,
                       completedAt: Date(), syncState: owner == nil ? .deviceOnly : .synced)
    }
    private func url(_ item: HistorySession, _ suffix: String) -> URL {
        library.root.appendingPathComponent(item.ownerID?.uuidString ?? "guest").appendingPathComponent(item.id.uuidString + suffix)
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testDeleteSessionRemovesItsFilesAndBlocksLateRecreation() async throws {
        let removed = item(), kept = item(owner: UUID())
        try library.save(removed); try library.save(kept)
        let source = root.appendingPathComponent("external.mov"); try write(source)
        try await library.retainVideo(source, for: removed)
        try await library.retainVideo(source, for: kept)
        for suffix in [".replay.plist", ".edit.plist", ".analysis.plist", ".motion.plist", ".import-source"] {
            try write(url(removed, suffix))
        }
        try library.saveRequest(.init(item: removed, result: nil, videoURL: source))
        try library.removeLocalSession(removed)
        XCTAssertNil(try library.session(id: removed.id, owner: nil))
        XCTAssertTrue(try library.pendingRequests(owner: nil).isEmpty)
        XCTAssertNil(library.videoURL(for: removed))
        XCTAssertEqual(try library.sessions(owner: kept.ownerID), [kept])
        XCTAssertNotNil(library.videoURL(for: kept))
        XCTAssertTrue(exists(source))
        let remaining = try files.files(in: url(removed, "").deletingLastPathComponent())
        XCTAssertEqual(remaining.map(\.lastPathComponent), [removed.id.uuidString + ".session-removed"])
        XCTAssertThrowsError(try library.save(removed))
        XCTAssertThrowsError(try library.saveRequest(.init(item: removed, result: nil, videoURL: source)))
        XCTAssertThrowsError(try library.saveReplayEdit(.init(edit: .init(style: .none, intensity: 0), overlays: .init()), id: removed.id, owner: nil))
        do { try await library.retainVideo(source, for: removed); XCTFail("Deleted video was recreated") } catch { }
        let restored = SessionHistoryLibrary(root: library.root)
        XCTAssertTrue(restored.isLocallyDeleted(id: removed.id, owner: nil))
        try write(url(removed, ".partial"))
        try restored.reconcileLocalRemovals(owner: nil)
        XCTAssertFalse(exists(url(removed, ".partial")))
    }

    func testRemovedReplayCannotBeRecreatedByDelayedCopy() async throws {
        let session = item(); try library.save(session)
        let source = root.appendingPathComponent("source.mov"); try write(source)
        try library.removeVideo(for: session)
        do { try await library.retainVideo(source, for: session); XCTFail("Removed replay was recreated") } catch { }
        XCTAssertEqual(try library.sessions(owner: nil), [session])
        XCTAssertNil(library.videoURL(for: session))
    }

    func testCacheClearKeepsSessionsEditsAndUnretainedImports() async throws {
        let session = item(); try library.save(session)
        let source = files.temporaryRoot.appendingPathComponent("juggledude-" + UUID().uuidString + ".mov")
        try write(source); try await library.retainVideo(source, for: session)
        let unsaved = files.temporaryRoot.appendingPathComponent("juggledude-" + UUID().uuidString + ".mov")
        try write(unsaved, Data([9, 8, 7]))
        let unrelated = files.temporaryRoot.appendingPathComponent("user-video.mov"); try write(unrelated)
        let export = files.temporaryRoot.appendingPathComponent("juggledude-edited-" + UUID().uuidString + ".mp4"); try write(export)
        let modelCache = files.cacheRoot.appendingPathComponent("Model/runtime.bin"); try write(modelCache)
        for suffix in [".analysis.plist", ".motion.plist", ".edit.plist", ".replay.plist"] { try write(url(session, suffix)) }
        let benchmark = files.documentsRoot.appendingPathComponent("pipeline-9064.mov"); try write(benchmark)
        let before = try files.snapshot(); XCTAssertGreaterThan(before.cached, 0)
        try files.clearCaches()
        XCTAssertFalse(exists(source)); XCTAssertFalse(exists(export)); XCTAssertFalse(exists(modelCache))
        XCTAssertFalse(exists(url(session, ".analysis.plist"))); XCTAssertFalse(exists(url(session, ".motion.plist")))
        XCTAssertTrue(exists(url(session, ".edit.plist"))); XCTAssertTrue(exists(url(session, ".replay.plist")))
        XCTAssertNotNil(library.videoURL(for: session)); XCTAssertEqual(try library.sessions(owner: nil), [session])
        XCTAssertTrue(exists(unsaved)); XCTAssertTrue(exists(unrelated)); XCTAssertTrue(exists(benchmark))
        XCTAssertEqual(try files.snapshot().cached, 0)
    }

    func testCacheClearNeverFollowsSymlinks() throws {
        let outside = root.appendingPathComponent("Outside/keep.mov"); try write(outside)
        try FileManager.default.createDirectory(at: files.cacheRoot, withIntermediateDirectories: true)
        let link = files.cacheRoot.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        try files.clearCaches()
        XCTAssertTrue(exists(outside))
    }

    func testAutomaticCleanupWaitsForIdenticalRetainedCopy() async throws {
        let session = item(); try library.save(session)
        let source = files.temporaryRoot.appendingPathComponent("juggledude-" + UUID().uuidString + ".mov")
        try write(source)
        try files.cleanupRetainedImport(source: source, retained: url(session, ".mov"))
        XCTAssertTrue(exists(source))
        try await library.retainVideo(source, for: session)
        let manifest = url(session, ".import-source"); XCTAssertTrue(exists(manifest))
        try write(source, Data([4, 5, 6])) // Same length is not sufficient proof.
        try library.cleanupRetainedImport(id: session.id, owner: nil)
        XCTAssertTrue(exists(source))
        try write(source)
        try library.cleanupRetainedImport(id: session.id, owner: nil)
        XCTAssertFalse(exists(source)); XCTAssertFalse(exists(manifest))
        XCTAssertNotNil(library.videoURL(for: session))
    }

    func testSourceSpecificCleanupLeavesDifferentSameSizedVideo() throws {
        let original = root.appendingPathComponent("retained.mov"); try write(original)
        let matching = files.temporaryRoot.appendingPathComponent("juggledude-" + UUID().uuidString + ".mov")
        let different = files.temporaryRoot.appendingPathComponent("juggledude-" + UUID().uuidString + ".mov")
        try write(matching); try write(different, Data([7, 8, 9]))
        try files.removeTemporaryCopies(of: original)
        XCTAssertFalse(exists(matching)); XCTAssertTrue(exists(different)); XCTAssertTrue(exists(original))
    }

    func testRefreshAndPendingAccountResultDoNotRestoreDeletedLocalSession() async throws {
        let owner = UUID(), result = try SavedJugglingResult(ownerID: UUID(), touches: 7, duration: 2, source: .gallery)
        let value = try SavedJugglingResult(ownerID: owner, touches: 8, duration: 2, source: .gallery)
        let removed = HistorySession(result: value, syncState: .synced)
        let queue = JugglingResultQueue(root: root), service = FakePlayerDataService()
        try queue.save(value); try queue.save(result); try library.save(removed); try library.removeLocalSession(removed)
        service.historyPages = [.init(items: [removed], next: nil)]
        let store = SessionHistoryStore(service: service, queue: queue, library: library)
        store.useAccount(owner)
        XCTAssertTrue(store.items.isEmpty)
        await store.refresh()
        XCTAssertTrue(store.items.isEmpty); XCTAssertNil(store.errorMessage)
        try await store.markSynced(value)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(try queue.pending(for: owner), [value], "Local cleanup must not silently delete account submissions")
    }

    func testDeleteWaitsForSaveAndCannotBeResurrectedByItsCopy() async throws {
        let suite = "StorageGuest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerStore(service: nil, queue: .init(root: root), guestDefaults: defaults,
            archiveVideo: { source, item, library in
                try await Task.sleep(for: .milliseconds(150))
                try await library.retainVideo(source, for: item)
            })
        await player.useAccount(nil)
        let source = files.temporaryRoot.appendingPathComponent("juggledude-" + UUID().uuidString + ".mov")
        try write(source)
        let summary = SessionSummary.make(touches: 8, duration: 2, bestCombo: 8, personalBest: 8,
            videoURL: source, touchesMarked: [], track: [])
        let id = UUID()
        let save = player.recordSession(id: id, owner: nil, summary: summary, source: .gallery, completedAt: Date())
        let session = try XCTUnwrap(player.history.items.first)
        let removed = await player.removeLocalSession(session)
        await save?.value
        XCTAssertTrue(removed)
        XCTAssertTrue(player.history.items.isEmpty)
        XCTAssertNil(player.history.library.videoURL(for: session))
        XCTAssertFalse(exists(source))
        XCTAssertFalse(player.isManagingLocalStorage)
    }

    func testEditorCloseCleansImportAfterReadersFinish() async throws {
        let suite = "StorageClose-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerStore(service: nil, queue: .init(root: root), guestDefaults: defaults)
        await player.useAccount(nil)
        let source = files.temporaryRoot.appendingPathComponent("juggledude-" + UUID().uuidString + ".mov")
        try write(source)
        let summary = SessionSummary.make(touches: 8, duration: 2, bestCombo: 8, personalBest: 8,
            videoURL: source, touchesMarked: [], track: [])
        let save = player.recordSession(id: UUID(), owner: nil, summary: summary, source: .gallery, completedAt: Date())
        await save?.value
        let session = try XCTUnwrap(player.history.items.first)
        let reader = try VideoStorageAccess.beginRead()
        player.releaseSessionImport(id: session.id, owner: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(exists(source))
        reader.release()
        for _ in 0..<150 where exists(source) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(exists(source))
        XCTAssertNotNil(player.history.library.videoURL(for: session))
    }

    func testMaintenanceCannotStartUntilAllReadersRelease() async throws {
        let first = try VideoStorageAccess.beginRead()
        let second = try VideoStorageAccess.beginRead()
        do { try await VideoStorageMaintenance.run { XCTFail("Cleanup overlapped readers") }; XCTFail("Cleanup admitted") } catch { }
        first.release(); first.release() // Idempotent release cannot drop another reader.
        do { try await VideoStorageMaintenance.run { XCTFail("One reader is still active") }; XCTFail("Cleanup admitted") } catch { }
        second.release()
        try await VideoStorageMaintenance.run {
            XCTAssertThrowsError(try VideoStorageAccess.beginRead())
        }
        let after = try VideoStorageAccess.beginRead(); after.release()
    }

    func testMaintenanceBlocksNewVideoJobsAndReleasesGateAfterFailure() async throws {
        enum Deliberate: Error { case failure }
        do {
            try await VideoStorageMaintenance.run {
                XCTAssertTrue(VideoStorageMaintenance.isActive)
                do {
                    try await VideoBackgroundWork.shared.run(title: "Should not start") { XCTFail("Processing started during cleanup") }
                    XCTFail("Job was admitted")
                } catch { }
                throw Deliberate.failure
            }
        } catch { }
        XCTAssertFalse(VideoStorageMaintenance.isActive)
    }
}
