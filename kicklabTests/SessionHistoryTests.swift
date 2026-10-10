import XCTest
@testable import kicklab

@MainActor
final class SessionHistoryTests: XCTestCase {
    private let owner = UUID()
    private var root: URL!
    private var queue: JugglingResultQueue!
    private var library: SessionHistoryLibrary!
    override func setUp() {
        root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        queue = JugglingResultQueue(root: root)
        library = SessionHistoryLibrary(root: root.appendingPathComponent("History"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func result(touches: Int = 42, date: Date = Date()) throws -> SavedJugglingResult {
        try .init(ownerID: owner, touches: touches, duration: 30.25, source: .recording, completedAt: date)
    }
    private func store(_ service: FakePlayerDataService) -> SessionHistoryStore {
        SessionHistoryStore(service: service, queue: queue, library: library)
    }
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    func testAccountDeletionRemovesOnlyItsReplaysAndBlocksLateWrites() async throws {
        let other = UUID(), player = PlayerStore(service: nil, queue: queue)
        let deletedResult = try result()
        let otherResult = try SavedJugglingResult(ownerID: other, touches: 7, duration: 2, source: .recording)
        let guest = HistorySession(id: UUID(), ownerID: nil, touches: 3, durationMS: 1000,
                                   source: .gallery, completedAt: Date(), syncState: .deviceOnly)
        try queue.save(deletedResult); try queue.save(otherResult)
        let item = HistorySession(result: deletedResult)
        try library.save(item); try library.save(HistorySession(result: otherResult)); try library.save(guest)
        let source = root.appendingPathComponent("source.mov")
        try Data([1, 2, 3]).write(to: source)
        try await library.retainVideo(source, for: item)
        await player.useAccount(.init(id: owner, email: nil, name: nil))
        let removed = await player.removeDeletedAccountData(owner)
        XCTAssertTrue(removed)
        XCTAssertNil(player.userID)
        XCTAssertTrue(try queue.pending(for: owner).isEmpty)
        XCTAssertTrue(try library.sessions(owner: owner).isEmpty)
        XCTAssertNil(library.videoURL(for: item))
        XCTAssertEqual(try queue.pending(for: other), [otherResult])
        XCTAssertEqual(try library.sessions(owner: nil), [guest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Unowned source/export files stay intact")
        XCTAssertThrowsError(try queue.save(deletedResult))
        XCTAssertThrowsError(try library.save(item))
        XCTAssertThrowsError(try library.saveRequest(.init(item: item, result: deletedResult, videoURL: source)))
        do { try await library.retainVideo(source, for: item); XCTFail("Late copy recreated deleted replay") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(owner.uuidString).path))
    }

    func testInterruptedAccountCleanupRetriesBeforeLoadingHistory() async throws {
        let saved = try result()
        try queue.save(saved); try library.save(HistorySession(result: saved))
        try queue.markDeleted(owner)
        let restored = PlayerStore(service: nil, queue: queue)
        await restored.useAccount(nil)
        XCTAssertTrue(queue.pendingDeletions().isEmpty)
        XCTAssertTrue(try library.sessions(owner: owner).isEmpty)
        XCTAssertTrue(try queue.pending(for: owner).isEmpty)
        await restored.useAccount(.init(id: owner, email: nil, name: nil))
        XCTAssertNil(restored.userID, "A stale identity cannot reactivate a deleted account")
    }

    func testExistingOutboxAppearsOfflineThenSurvivesSuccessfulSyncAndRestart() async throws {
        let saved = try result()
        try queue.save(saved) // Upgrade from the old outbox-only build.
        let service = FakePlayerDataService(); service.historyFails = true
        let history = store(service); history.useAccount(owner)
        await history.refresh()
        XCTAssertEqual(history.items.map(\.id), [saved.id])
        XCTAssertEqual(history.items.first?.syncState, .pending)
        XCTAssertNotNil(history.errorMessage)

        let player = PlayerStore(service: service, queue: queue)
        await player.useAccount(.init(id: owner, email: nil, name: nil))
        await settle { service.attempts.count == 1 && player.pendingCount == 0 }
        XCTAssertTrue(try queue.pending(for: owner).isEmpty)
        let restored = store(service); restored.useAccount(owner)
        XCTAssertEqual(restored.items.map(\.id), [saved.id])
        XCTAssertEqual(restored.items.first?.syncState, .synced)
    }

    func testPagesMergeWithPendingWithoutDuplicatesAndCanBeReadOffline() async throws {
        let a = try result(), b = try result(touches: 18, date: Date().addingTimeInterval(-100))
        try queue.save(a)
        let cursor = SessionHistoryCursor(timestamp: "2026-10-08T12:00:00.123456+00:00", id: a.id)
        let service = FakePlayerDataService()
        service.historyPages = [
            .init(items: [HistorySession(result: a, syncState: .synced)], next: cursor),
            .init(items: [HistorySession(result: b, syncState: .synced)], next: nil)
        ]
        let history = store(service); history.useAccount(owner)
        await history.refresh()
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.items.first?.syncState, .synced)
        XCTAssertTrue(history.hasMore)
        await history.loadMore()
        XCTAssertEqual(history.items.map(\.id), [a.id, b.id])
        XCTAssertEqual(service.historyCalls.last?.1, cursor)
        XCTAssertFalse(history.hasMore)
        service.historyFails = true
        let restored = store(service); restored.useAccount(owner)
        await restored.refresh()
        XCTAssertEqual(restored.items.map(\.id), [a.id, b.id])
        XCTAssertNotNil(restored.errorMessage)
    }

    func testLatePageCannotLeakAfterAccountSwitchOrSignOut() async throws {
        let service = FakePlayerDataService(); service.pauseHistory = true
        service.historyPages = [.init(items: [HistorySession(result: try result(), syncState: .synced)], next: nil)]
        let history = store(service); history.useAccount(owner)
        let task = Task { await history.refresh() }
        await settle { service.historyContinuation != nil }
        history.useAccount(UUID())
        service.historyContinuation?.resume(); service.historyContinuation = nil
        await task.value
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertFalse(history.isLoading)
        history.useAccount(nil)
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertNil(history.ownerID)
    }

    func testNewRefreshWinsOverOlderInFlightPage() async throws {
        let old = try result(touches: 7), new = try result(touches: 31)
        let service = FakePlayerDataService(); service.pauseHistory = true
        service.historyPages = [.init(items: [HistorySession(result: old, syncState: .synced)], next: nil)]
        let history = store(service); history.useAccount(owner)
        let first = Task { await history.refresh() }
        await settle { service.historyContinuation != nil }
        service.pauseHistory = false
        service.historyPages = [.init(items: [HistorySession(result: new, syncState: .synced)], next: nil)]
        await history.refresh()
        service.historyContinuation?.resume(); service.historyContinuation = nil
        await first.value
        XCTAssertEqual(history.items.map(\.id), [new.id])
        XCTAssertFalse(history.isLoading)
    }

    func testVideoSurvivesTemporarySourceRemovalAndRemovingReplayKeepsResult() async throws {
        let item = HistorySession(result: try result(), syncState: .synced)
        try library.save(item)
        let source = root.appendingPathComponent("temporary.mov")
        try Data([0, 1, 2, 3]).write(to: source)
        try await library.retainVideo(source, for: item)
        try FileManager.default.removeItem(at: source)
        let restored = SessionHistoryLibrary(root: library.root)
        let replay = try XCTUnwrap(restored.videoURL(for: item))
        XCTAssertEqual(try Data(contentsOf: replay), Data([0, 1, 2, 3]))
        XCTAssertEqual(try replay.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try restored.removeVideo(for: item)
        XCTAssertNil(restored.videoURL(for: item))
        XCTAssertEqual(try restored.sessions(owner: owner), [item])
    }

    func testGuestSessionStaysLocalAndIsNotClaimedWhenSigningIn() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("guest.mov")
        try Data([1, 2, 3]).write(to: source)
        let service = FakePlayerDataService(), player = PlayerStore(service: nil, queue: queue)
        await player.useAccount(nil)
        let summary = SessionSummary.make(touches: 17, duration: 10, bestCombo: 17, personalBest: 17,
            videoURL: source, touchesMarked: [], track: [])
        let id = UUID()
        let saving = player.recordSession(id: id, owner: nil, summary: summary, source: .gallery, completedAt: Date())
        await saving?.value
        XCTAssertEqual(player.history.items.first?.id, id)
        XCTAssertEqual(player.history.items.first?.syncState, .deviceOnly)
        XCTAssertNotNil(player.history.library.videoURL(for: try XCTUnwrap(player.history.items.first)))
        let signedIn = PlayerStore(service: service, queue: queue)
        await signedIn.useAccount(.init(id: owner, email: nil, name: nil))
        await signedIn.history.refresh()
        XCTAssertTrue(signedIn.history.items.isEmpty)
        XCTAssertTrue(service.attempts.isEmpty)
        await signedIn.useAccount(nil)
        XCTAssertEqual(signedIn.history.items.first?.id, id)
    }

    func testFailedReplayCopyDoesNotLoseAccountResult() async throws {
        let service = FakePlayerDataService(), player = PlayerStore(service: nil, queue: queue)
        await player.useAccount(.init(id: owner, email: nil, name: nil))
        let summary = SessionSummary.make(touches: 9, duration: 5, bestCombo: 9, personalBest: 9,
            videoURL: root.appendingPathComponent("missing.mov"), touchesMarked: [], track: [])
        let saving = player.recordSession(id: UUID(), owner: owner, summary: summary, source: .recording, completedAt: Date())
        await saving?.value
        XCTAssertEqual(try queue.pending(for: owner).count, 1)
        XCTAssertEqual(player.history.items.first?.touches, 9)
        XCTAssertNotNil(player.history.errorMessage)
        XCTAssertTrue(service.attempts.isEmpty)
    }

    func testPreviewAndHistoryStayAvailableWhileCopyAndUploadAreStalled() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("ready.mov")
        try Data([1, 2, 3]).write(to: source)
        let gate = ReplayCopyGate()
        let service = FakePlayerDataService(); service.pauseSubmit = true
        let player = PlayerStore(service: service, queue: queue, archiveVideo: { source, item, library in
            await gate.wait()
            try await library.retainVideo(source, for: item)
        })
        await player.useAccount(.init(id: owner, email: nil, name: nil))
        let summary = SessionSummary.make(touches: 23, duration: 10, bestCombo: 23, personalBest: 23,
            videoURL: source, touchesMarked: [], track: [])
        let saving = player.recordSession(id: UUID(), owner: owner, summary: summary, source: .recording, completedAt: Date())
        let item = try XCTUnwrap(player.history.items.first)
        XCTAssertEqual(item.syncState, .saving)
        XCTAssertEqual(player.history.replayURL(for: item), source, "Playback does not wait for the permanent copy")
        XCTAssertNil(library.videoURL(for: item))
        await settle { service.submitContinuation != nil }
        XCTAssertNotNil(player.history.replayURL(for: item))
        XCTAssertNil(player.errorMessage, "A delayed server must not interrupt the user")
        // Completion and original ownership are independent of the visible account.
        await player.useAccount(.init(id: UUID(), email: nil, name: nil))
        service.pauseSubmit = false
        service.submitContinuation?.resume(); service.submitContinuation = nil
        await gate.release()
        await saving?.value
        XCTAssertTrue(player.history.items.isEmpty)
        XCTAssertNil(player.history.replayURL(for: item))
        XCTAssertNotNil(library.videoURL(for: item))
        XCTAssertTrue(try library.pendingRequests(owner: owner).isEmpty)
    }

    func testCloudCanFinishBeforeVideoCopyWithoutDowngradingSyncedState() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("ready.mov")
        try Data([1, 2, 3]).write(to: source)
        let gate = ReplayCopyGate(), service = FakePlayerDataService()
        let player = PlayerStore(service: service, queue: queue, archiveVideo: { source, item, library in
            await gate.wait(); try await library.retainVideo(source, for: item)
        })
        await player.useAccount(.init(id: owner, email: nil, name: nil))
        let summary = SessionSummary.make(touches: 12, duration: 8, bestCombo: 12, personalBest: 12,
            videoURL: source, touchesMarked: [], track: [])
        let saving = player.recordSession(id: UUID(), owner: owner, summary: summary, source: .gallery, completedAt: Date())
        await settle { player.history.items.first?.syncState == .synced }
        let item = try XCTUnwrap(player.history.items.first)
        XCTAssertNil(library.videoURL(for: item))
        XCTAssertEqual(player.history.replayURL(for: item), source)
        await gate.release(); await saving?.value
        XCTAssertEqual(player.history.items.first?.syncState, .synced)
        XCTAssertEqual(try library.sessions(owner: owner).first?.syncState, .synced)
        XCTAssertNotNil(library.videoURL(for: item))
    }

    func testInterruptedReplaySaveRecoversOnRelaunchWithoutResubmittingSyncedResult() async throws {
        let result = try result()
        let item = HistorySession(result: result, syncState: .synced)
        try library.save(item)
        let source = root.appendingPathComponent("original.mov")
        try Data([5, 6]).write(to: source)
        try library.saveRequest(.init(item: HistorySession(result: result), result: result, videoURL: source))
        let service = FakePlayerDataService()
        let player = PlayerStore(service: service, queue: queue)
        await player.useAccount(.init(id: owner, email: nil, name: nil))
        await settle { (try? self.library.pendingRequests(owner: self.owner).isEmpty) == true }
        XCTAssertNotNil(library.videoURL(for: item))
        XCTAssertEqual(player.history.items.first?.syncState, .synced)
        XCTAssertTrue(service.attempts.isEmpty)
    }

    func testServerModerationStatusReplacesCachedStatus() async throws {
        let original = HistorySession(result: try result(), syncState: .synced)
        try library.save(original)
        var rejected = original; rejected.scoreStatus = "rejected"
        let service = FakePlayerDataService()
        service.historyPages = [.init(items: [rejected], next: nil)]
        let history = store(service); history.useAccount(owner)
        await history.refresh()
        XCTAssertEqual(history.items.first?.scoreStatus, "rejected")
    }

    func testCloudDecodePreservesCursorPrecisionAndSupportsWholeSecondDates() throws {
        let stamp = "2026-10-08T12:34:56.123456+00:00"
        let rows = (0..<31).map { index -> [String: Any] in
            ["id": UUID().uuidString, "user_id": owner.uuidString, "touch_count": index,
             "duration_ms": 12500, "source": index % 2 == 0 ? "recording" : "gallery",
             "completed_at": index == 0 ? "2026-10-09T12:34:56+00:00" : stamp, "score_status": "device_reported"]
        }
        let page = try SessionHistoryPage.decode(JSONSerialization.data(withJSONObject: rows), owner: owner)
        XCTAssertEqual(page.items.count, 30)
        XCTAssertEqual(page.next?.timestamp, stamp)
        XCTAssertEqual(page.next?.id.uuidString, rows[29]["id"] as? String)
        XCTAssertEqual(page.items[1].source, .gallery)
        XCTAssertEqual(page.items[0].syncState, .synced)
        XCTAssertThrowsError(try SessionHistoryPage.decode(JSONSerialization.data(withJSONObject: rows), owner: UUID()))
        var bad = rows[0]; bad["completed_at"] = "invalid"
        XCTAssertThrowsError(try SessionHistoryPage.decode(JSONSerialization.data(withJSONObject: [bad]), owner: owner))
    }

    func testHistoryRequestUsesOwnerAuthAndEscapesOffsetPlus() async throws {
        let config = try AccountConfiguration(values: ["SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test", "AUTH_REDIRECT_URL": "juggledude://auth/callback"])
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [HistoryURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let expectedOwner = owner
        let service = SupabasePlayerService(config: config, session: session) { id in
            XCTAssertEqual(id, expectedOwner); return "test-access-token"
        }
        let cursor = SessionHistoryCursor(timestamp: "2026-10-08T12:34:56.123456+00:00", id: UUID())
        _ = try await service.history(userID: owner, before: cursor)
        let request = try XCTUnwrap(HistoryURLProtocol.captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertTrue(request.url!.absoluteString.contains("%2B00:00"))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "user_id" }?.value, "eq.\(owner.uuidString)")
        XCTAssertEqual(query.first { $0.name == "order" }?.value, "completed_at.desc,id.desc")
        XCTAssertTrue(query.first { $0.name == "or" }!.value!.contains("id.lt.\(cursor.id.uuidString)"))
    }
}

private actor ReplayCopyGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

private final class HistoryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var captured: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
