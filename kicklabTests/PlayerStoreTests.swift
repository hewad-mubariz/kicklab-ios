import XCTest
@testable import kicklab

@MainActor
final class PlayerStoreTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func identity(_ id: UUID) -> AccountIdentity { .init(id: id, email: nil, name: nil) }
    private func result(_ owner: UUID, touches: Int = 12) throws -> SavedJugglingResult {
        try .init(ownerID: owner, touches: touches, duration: 20, source: .recording)
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for state")
    }

    func testQueueSurvivesRestartAndSeparatesAccounts() throws {
        let queue = JugglingResultQueue(root: root)
        let first = try result(a), second = try result(b)
        try queue.save(first); try queue.save(first); try queue.save(second)
        let restored = JugglingResultQueue(root: root)
        XCTAssertEqual(try restored.pending(for: a), [first])
        XCTAssertEqual(try restored.pending(for: b), [second])
        try restored.remove(first)
        XCTAssertTrue(try restored.pending(for: a).isEmpty)
        XCTAssertEqual(try restored.pending(for: b), [second])
    }

    func testResultRejectsInvalidCountsAndDurations() {
        for (count, duration) in [(-1, 2.0), (1_000_001, 2.0), (10, 0.0), (10, Double.nan), (10, Double.infinity), (10, 86401.0)] {
            XCTAssertThrowsError(try SavedJugglingResult(ownerID: a, touches: count, duration: duration, source: .recording))
        }
    }

    func testFailedUploadIsKeptAndRetryUsesSameID() async throws {
        let service = FakePlayerDataService(); service.submitFails = true
        let queue = JugglingResultQueue(root: root)
        let store = PlayerStore(service: service, queue: queue)
        await store.useAccount(identity(a))
        store.record(try result(a))
        await waitUntil { service.attempts.count == 1 }
        XCTAssertNil(store.errorMessage, "Routine offline sync must stay quiet")
        XCTAssertEqual(try queue.pending(for: a).count, 1)
        XCTAssertEqual(store.pendingCount, 1)
        service.submitFails = false
        store.syncPending()
        await waitUntil { store.pendingCount == 0 }
        XCTAssertEqual(service.attempts.count, 2)
        XCTAssertEqual(service.attempts.first?.id, service.attempts.last?.id)
        XCTAssertTrue(try queue.pending(for: a).isEmpty)
    }

    func testNewResultDuringSyncIsAlsoDrained() async throws {
        let service = FakePlayerDataService(); service.pauseSubmit = true
        let store = PlayerStore(service: service, queue: .init(root: root))
        await store.useAccount(identity(a))
        store.record(try result(a))
        await waitUntil { service.submitContinuation != nil }
        store.record(try result(a, touches: 30))
        service.pauseSubmit = false
        service.submitContinuation?.resume(); service.submitContinuation = nil
        await waitUntil { store.pendingCount == 0 }
        XCTAssertEqual(service.attempts.count, 2)
        XCTAssertEqual(store.personalBest, 30)
    }

    func testTransientFailureRetriesAutomaticallyWithoutShowingAnError() async throws {
        let service = FakePlayerDataService(); service.submitFails = true
        let queue = JugglingResultQueue(root: root)
        let store = PlayerStore(service: service, queue: queue, syncRetryDelay: .milliseconds(40))
        await store.useAccount(identity(a))
        store.record(try result(a))
        await waitUntil { !service.attempts.isEmpty }
        XCTAssertNil(store.errorMessage)
        service.submitFails = false
        await waitUntil { service.attempts.count >= 2 && store.pendingCount == 0 }
        XCTAssertEqual(Set(service.attempts.map(\.id)).count, 1)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(try queue.pending(for: a).isEmpty)
    }

    func testChangingAccountDoesNotUploadPreviousAccountsQueue() async throws {
        let service = FakePlayerDataService(); service.submitFails = true
        let queue = JugglingResultQueue(root: root)
        let store = PlayerStore(service: service, queue: queue)
        await store.useAccount(identity(a))
        store.record(try result(a, touches: 100))
        await waitUntil { service.attempts.count == 1 }
        service.submitFails = false; service.attempts = []
        await store.useAccount(identity(b))
        store.record(try result(b, touches: 7))
        await waitUntil { store.pendingCount == 0 }
        XCTAssertEqual(service.attempts.map(\.ownerID), [b])
        XCTAssertEqual(try queue.pending(for: a).count, 1)
        XCTAssertEqual(store.profile?.id, b)
        XCTAssertEqual(store.personalBest, 7)
    }

    func testLateProfileResponseCannotReplaceNewAccount() async {
        let service = FakePlayerDataService(); service.pausedProfileID = a
        let store = PlayerStore(service: service, queue: .init(root: root))
        let first = Task { await store.useAccount(identity(a)) }
        await waitUntil { service.profileContinuation != nil }
        await store.useAccount(identity(b))
        service.profileContinuation?.resume(); service.profileContinuation = nil
        await first.value
        XCTAssertEqual(store.userID, b)
        XCTAssertEqual(store.profile?.id, b)
    }

    func testSignOutClearsAccountStateAndPhoto() async throws {
        let store = PlayerStore(service: FakePlayerDataService(), queue: .init(root: root))
        await store.useAccount(identity(a))
        try await store.uploadAvatar(Data([1, 2, 3]))
        XCTAssertNotNil(store.avatarData)
        await store.useAccount(nil)
        XCTAssertNil(store.profile); XCTAssertNil(store.avatarData); XCTAssertNil(store.userID)
        XCTAssertEqual(store.personalBest, 0)
    }

    func testProfileValidationAndExplicitLeaderboardOptIn() async throws {
        let service = FakePlayerDataService()
        let store = PlayerStore(service: service, queue: .init(root: root))
        await store.useAccount(identity(a))
        XCTAssertEqual(store.profile?.leaderboardVisible, false)
        try await store.updateProfile(name: "  My name  ", country: "DE", visible: true)
        XCTAssertEqual(service.savedProfile?.displayName, "My name")
        XCTAssertEqual(service.savedProfile?.leaderboardVisible, true)
        do {
            try await store.updateProfile(name: "", country: "DE", visible: true)
            XCTFail("Empty name accepted")
        } catch { }
    }
}

@MainActor
final class FakePlayerDataService: PlayerDataService {
    var submitFails = false
    var pauseSubmit = false
    var attempts: [SavedJugglingResult] = []
    var submitContinuation: CheckedContinuation<Void, Never>?
    var pausedProfileID: UUID?
    var profileContinuation: CheckedContinuation<Void, Never>?
    var savedProfile: PlayerProfile?
    var historyPages: [SessionHistoryPage] = []
    var historyFails = false
    var historyCalls: [(UUID, SessionHistoryCursor?)] = []
    var pauseHistory = false
    var historyContinuation: CheckedContinuation<Void, Never>?
    func history(userID: UUID, before: SessionHistoryCursor?) async throws -> SessionHistoryPage {
        historyCalls.append((userID, before))
        let page = historyPages.isEmpty ? SessionHistoryPage(items: [], next: nil) : historyPages.removeFirst()
        if pauseHistory { await withCheckedContinuation { historyContinuation = $0 } }
        if historyFails { throw URLError(.notConnectedToInternet) }
        return page
    }
    func profile(userID: UUID) async throws -> PlayerProfile {
        if userID == pausedProfileID { await withCheckedContinuation { profileContinuation = $0 } }
        return .init(id: userID, displayName: "Player", countryCode: nil, avatarPath: nil, leaderboardVisible: false)
    }
    func personalBest(userID: UUID) async throws -> Int { 0 }
    func saveProfile(_ profile: PlayerProfile) async throws -> PlayerProfile { savedProfile = profile; return profile }
    func submit(_ result: SavedJugglingResult) async throws {
        attempts.append(result)
        if pauseSubmit { await withCheckedContinuation { submitContinuation = $0 } }
        if submitFails { throw URLError(.notConnectedToInternet) }
    }
    func leaderboard(period: String, country: String?, userID: UUID?) async throws -> JugglingLeaderboard {
        .init(entries: [], aroundMe: [], totalPlayers: 0)
    }
    func avatarURL(path: String, userID: UUID?) async throws -> URL { throw PlayerDataError.requestFailed }
    func uploadAvatar(_ jpeg: Data, userID: UUID) async throws { }
    func deleteAvatar(userID: UUID) async throws { }
}
