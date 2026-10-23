import XCTest
@testable import kicklab

/// A leaderboard submission is kept on the phone until it can send: offline, or
/// before its session has synced, it waits and then sends itself.
@MainActor
final class LeaderboardQueueTests: XCTestCase {
    private final class FakeReviewService: LeaderboardReviewService {
        var offline = false
        var beginFailure: LeaderboardFailure?
        private(set) var begun = 0
        /// The flagged moments the last registered attempt carried.
        private(set) var sentReview: LeaderboardTouchReview?
        private var stored: [LeaderboardAttempt] = []
        private var uploaded = Set<UUID>()

        func attempts(owner: UUID) async throws -> [LeaderboardAttempt] {
            if offline { throw URLError(.notConnectedToInternet) }
            return stored
        }
        func begin(item: HistorySession, proposal: RankedStreakProposal, bytes: Int64, sha256: String) async throws -> LeaderboardAttempt {
            if offline { throw URLError(.notConnectedToInternet) }
            if let beginFailure { throw beginFailure }
            begun += 1
            sentReview = item.touchReview
            let attempt = Self.attempt(item: item, proposal: proposal, bytes: bytes, sha256: sha256, status: .uploading)
            stored.insert(attempt, at: 0)
            return attempt
        }
        func finish(id: UUID, owner: UUID) async throws -> LeaderboardAttempt {
            if offline { throw URLError(.notConnectedToInternet) }
            guard uploaded.contains(id), let index = stored.firstIndex(where: { $0.id == id }) else { throw LeaderboardFailure.upload }
            let done = stored[index]
            stored[index] = Self.attempt(id: done.id, item: nil, owner: done.userID, session: done.sessionID,
                proposal: done.proposal, bytes: done.videoBytes, sha256: done.videoSHA256, status: .pending)
            return stored[index]
        }
        func upload(file: URL, attempt: LeaderboardAttempt, checkpoint: URL, accountRoot: URL,
                    progress: @escaping @MainActor (Double) -> Void) async throws {
            if offline { throw URLError(.networkConnectionLost) }
            uploaded.insert(attempt.id); progress(1)
        }
        func withdraw(id: UUID, owner: UUID) async throws {}
        func appeal(id: UUID, reason: String, owner: UUID) async throws {}
        func report(id: UUID, reason: String, owner: UUID) async throws {}
        func videoURL(attempt: LeaderboardAttempt, owner: UUID) async throws -> URL { throw LeaderboardFailure.unavailable }

        static func attempt(id: UUID = UUID(), item: HistorySession?, owner: UUID? = nil, session: UUID? = nil,
                            proposal: RankedStreakProposal, bytes: Int64, sha256: String,
                            status: LeaderboardAttempt.Status) -> LeaderboardAttempt {
            LeaderboardAttempt(id: id, userID: owner ?? item!.ownerID!, sessionID: session ?? item!.id, status: status,
                proposedCount: proposal.count, proposedStartMS: proposal.startMS, proposedEndMS: proposal.endMS,
                durationMS: 10_000, videoBytes: bytes, videoSHA256: sha256, objectPath: "test/\(id).mov",
                createdAt: Date(), submittedAt: nil, reviewedCount: nil, reviewedStartMS: nil, reviewedEndMS: nil,
                reviewedAt: nil, reviewReason: nil, reasonTimeMS: nil, appealAt: nil, videoDeletedAt: nil,
                videoDeleteRequestedAt: nil)
        }
    }

    private let owner = UUID()
    private let proposal = RankedStreakProposal(count: 18, startMS: 500, endMS: 9_000)
    private var root: URL!
    private var video: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("leaderboard-queue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        video = root.appendingPathComponent("original.mov")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        try FileManager.default.copyItem(at: fixture, to: video)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func session(_ state: HistorySession.SyncState) -> HistorySession {
        HistorySession(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, ownerID: owner, touches: 20,
                       durationMS: 10_000, source: .recording, completedAt: Date(), syncState: state)
    }

    private func store(_ service: FakeReviewService, item: @escaping () -> HistorySession) -> LeaderboardReviewStore {
        let store = LeaderboardReviewStore(service: service, root: root, retryDelay: .seconds(60))
        store.useAccount(owner)
        let video = video!
        store.resolveQueued = { id in id == item().id ? (item(), video) : nil }
        return store
    }

    private func settle(_ store: LeaderboardReviewStore) async throws {
        for _ in 0..<200 where store.uploadingSession != nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
    }

    func testOfflineSubmissionWaitsThenSendsWhenBackOnline() async throws {
        let service = FakeReviewService()
        service.offline = true
        let item = session(.synced)
        let store = store(service) { item }

        store.enqueue(item: item, proposal: proposal)
        try await settle(store)
        XCTAssertTrue(store.isQueued(item.id), "Offline, the submission stays on the phone")
        XCTAssertTrue(store.waitingForConnection)
        XCTAssertNil(store.errorMessage, "Being offline is not an error the player has to act on")

        service.offline = false
        store.sendQueued() // What a regained connection does.
        try await settle(store)
        XCTAssertFalse(store.isQueued(item.id))
        XCTAssertFalse(store.waitingForConnection)
        XCTAssertEqual(store.attempt(for: item.id)?.status, .pending)
        XCTAssertEqual(service.begun, 1)
    }

    func testQueueSurvivesRelaunch() async throws {
        let service = FakeReviewService()
        service.offline = true
        let item = session(.synced)
        let first = store(service) { item }
        first.enqueue(item: item, proposal: proposal)
        try await settle(first)

        let relaunched = LeaderboardReviewStore(service: service, root: root)
        relaunched.useAccount(owner)
        XCTAssertEqual(relaunched.queued.map(\.sessionID), [item.id])
        XCTAssertEqual(relaunched.queued.first?.proposal, proposal)
    }

    func testWaitsForTheSessionToSyncFirst() async throws {
        let service = FakeReviewService()
        var item = session(.pending)
        let store = store(service) { item }

        store.enqueue(item: item, proposal: proposal)
        try await settle(store)
        XCTAssertTrue(store.isQueued(item.id))
        XCTAssertEqual(service.begun, 0, "Nothing is sent before the session reaches the account")

        item.syncState = .synced
        store.sendQueued() // What a finished result sync does.
        try await settle(store)
        XCTAssertFalse(store.isQueued(item.id))
        XCTAssertEqual(service.begun, 1)
    }

    func testRefusalDropsTheSubmissionAndSaysWhy() async throws {
        let service = FakeReviewService()
        service.beginFailure = .limit
        let item = session(.synced)
        let store = store(service) { item }

        store.enqueue(item: item, proposal: proposal)
        try await settle(store)
        XCTAssertFalse(store.isQueued(item.id), "A refusal is not retried forever")
        XCTAssertEqual(store.errorMessage, LeaderboardFailure.limit.localizedDescription)
    }

    func testACheckSendsOnlyTheChosenMoments() async throws {
        let service = FakeReviewService()
        var item = session(.synced)
        let unsure = LeaderboardReviewMoment(kind: .handsUncertain, timeMS: 2_000, lastTimeMS: 2_000, clipStartMS: 1_000, clipEndMS: 3_200)
        let ground = LeaderboardReviewMoment(kind: .groundContact, timeMS: 6_000, lastTimeMS: 6_000, clipStartMS: 5_000, clipEndMS: 7_200)
        item.touchReview = LeaderboardTouchReview(version: 1, durationMS: 10_000, complete: true, moments: [unsure, ground])
        let store = store(service) { item }
        let chosen = LeaderboardTouchReview(version: 1, durationMS: 10_000, complete: true, moments: [unsure])

        store.enqueue(item: item, proposal: proposal, request: chosen)
        try await settle(store)
        XCTAssertEqual(store.attempt(for: item.id)?.status, .pending)
        XCTAssertEqual(service.sentReview, chosen, "The ground call the player didn't ask about is not sent")
    }

    func testOnlyConnectionProblemsAreRetried() {
        XCTAssertTrue(LeaderboardReviewStore.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(LeaderboardReviewStore.isTransient(LeaderboardFailure.upload))
        XCTAssertFalse(LeaderboardReviewStore.isTransient(LeaderboardFailure.limit))
        XCTAssertFalse(LeaderboardReviewStore.isTransient(LeaderboardFailure.changedVideo))
    }
}
