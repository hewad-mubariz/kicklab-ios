import XCTest
@testable import kicklab

@MainActor
final class PersonalBestStreakTests: XCTestCase {
    func testPersonalBestUsesLongestRunAndDoesNotCelebrateAnEqualRecord() throws {
        let times = (1...60).map(Double.init)
        var evidence = TouchReviewEvidence()
        for time in [20.5, 50.5] {
            evidence.append(.init(frameIndex: Int(time * 30), time: time, rejection: .groundBounce,
                                  handConfirmed: false, bodyFailure: nil, ball: nil), groundConfirmed: true)
        }
        var summary = SessionSummary.make(touches: 60, duration: 65, bestCombo: 60, personalBest: 29,
            videoURL: URL(fileURLWithPath: "/tmp/test.mov"),
            touchesMarked: times.enumerated().map { .init(index: $0.offset + 1, time: $0.element, x: 0.5, y: 0.5) }, track: [])
        // Gallery totals with no saved interruption evidence do not become records.
        XCTAssertNil(summary.bestStreak)
        XCTAssertFalse(summary.isNewBest)
        summary.leaderboardTouchReview = LeaderboardTouchReview.make(evidence: evidence, touchTimes: times, duration: 65)
        XCTAssertEqual(summary.bestStreak?.count, 30)
        XCTAssertTrue(summary.isNewBest)
        let tied = SessionSummary.make(touches: 60, duration: 65, bestCombo: 60, personalBest: 30,
                                      videoURL: summary.videoURL, touchesMarked: summary.touchesMarked, track: [])
        var withReview = tied; withReview.leaderboardTouchReview = summary.leaderboardTouchReview
        XCTAssertFalse(withReview.isNewBest)
    }

    func testGuestMigrationNeverTurnsLegacyTotalsOrImportsIntoStreaks() throws {
        let suite = "StreakMigration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(999, forKey: "kicklab.juggling.personalBest")
        func item(_ source: SavedJugglingResult.Source, streak: Int?, owner: UUID? = nil) -> HistorySession {
            var value = HistorySession(id: UUID(), ownerID: owner, touches: 100, durationMS: 60000,
                source: source, completedAt: Date(), syncState: .deviceOnly)
            value.rankedProposal = streak.map { .init(count: $0, startMS: 0, endMS: 50000) }
            return value
        }
        JugglingRecords.migrateGuestBest(from: [item(.recording, streak: nil), item(.gallery, streak: 100),
            item(.recording, streak: 80, owner: UUID()), item(.recording, streak: 30)], defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: JugglingRecords.bestKey), 30)
        JugglingRecords.recordIfNeeded(40, ownerID: nil, defaults: defaults)
        JugglingRecords.migrateGuestBest(from: [], defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: JugglingRecords.bestKey), 40)
    }

    func testQueuedAndRestoredRecordsUseStreakRatherThanSessionTotal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), service = FakePlayerDataService()
        service.submitFails = true
        var saved = try SavedJugglingResult(ownerID: owner, touches: 60, duration: 65, source: .recording)
        saved.rank(.init(count: 30, startMS: 20000, endMS: 50000))
        var imported = try SavedJugglingResult(ownerID: owner, touches: 500, duration: 65, source: .gallery)
        imported.rank(.init(count: 500, startMS: 0, endMS: 60000))
        let queue = JugglingResultQueue(root: root)
        try queue.save(saved); try queue.save(imported)
        let store = PlayerStore(service: service, queue: queue)
        await store.useAccount(.init(id: owner, email: nil, name: nil))
        XCTAssertEqual(store.personalBest, 30)
        XCTAssertEqual(HistorySession(result: saved).personalBestStreak, 30)
        XCTAssertEqual(HistorySession(result: imported).personalBestStreak, 0)
    }

    func testAccountBestQueryFiltersRecordingsAndOrdersStreaks() async throws {
        let config = try AccountConfiguration(values: ["SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test", "AUTH_REDIRECT_URL": "juggledude://auth/callback"])
        let options = URLSessionConfiguration.ephemeral; options.protocolClasses = [PersonalBestURLProtocol.self]
        let session = URLSession(configuration: options)
        defer { session.invalidateAndCancel(); PersonalBestURLProtocol.handler = nil }
        PersonalBestURLProtocol.handler = { request in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["select"], "streak_touches")
            XCTAssertEqual(query["order"], "streak_touches.desc")
            XCTAssertEqual(query["source"], "eq.recording")
            XCTAssertEqual(query["streak_touches"], "gt.0")
            XCTAssertEqual(query["score_status"], "neq.rejected")
            return (200, [:], Data("[{\"streak_touches\":30}]".utf8))
        }
        let service = SupabasePlayerService(config: config, session: session) { _ in "test" }
        let best = try await service.personalBest(userID: UUID())
        XCTAssertEqual(best, 30)
    }
}

private final class PersonalBestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String:String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, headers, data) = Self.handler?(request) ?? (500, [:], Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
