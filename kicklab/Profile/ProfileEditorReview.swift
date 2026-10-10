#if DEBUG
import Foundation

/// A separate account and local queue keep profile UI tests away from real data.
enum ProfileEditorReview {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--profile-editor-review") }
    static let identity = AccountIdentity(id: UUID(uuidString: "00000000-0000-0000-0000-000000000098")!,
                                          email: "profile@example.test", name: "Alex Rivera")
    static func account() -> AccountStore { AccountStore(service: ProfileReviewAccount()) }
    static func player() -> PlayerStore {
        PlayerStore(service: ProfileReviewData(), queue: .init(root: .temporaryDirectory.appendingPathComponent("JuggleDudeProfileReview-" + UUID().uuidString)))
    }
    static func refreshWhileReviewing(_ player: PlayerStore) async {
        guard requested, ProcessInfo.processInfo.arguments.contains("--profile-refresh-review") else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await player.refresh()
        }
    }
}

@MainActor
private final class ProfileReviewAccount: AccountAuthService {
    var changes: AsyncStream<AccountIdentity?> {
        AsyncStream { $0.yield(ProfileEditorReview.identity); $0.finish() }
    }
    func google() async throws -> AccountIdentity { ProfileEditorReview.identity }
    func apple() async throws -> AccountIdentity { ProfileEditorReview.identity }
    func sendLink(email: String) async throws { throw PlayerDataError.unavailable }
    func callback(_ url: URL) async throws -> AccountIdentity { throw PlayerDataError.unavailable }
    func signOut() async throws { }
    func setActive(_ active: Bool) async { }
}

@MainActor
private final class ProfileReviewData: PlayerDataService {
    var saved = PlayerProfile(id: ProfileEditorReview.identity.id, displayName: "Alex Rivera", countryCode: "DE", leaderboardVisible: false)
    func profile(userID: UUID) async throws -> PlayerProfile { saved }
    func personalBest(userID: UUID) async throws -> Int { 42 }
    func saveProfile(_ profile: PlayerProfile) async throws -> PlayerProfile {
        try await Task.sleep(for: .milliseconds(150))
        if ProcessInfo.processInfo.arguments.contains("--profile-save-failure") { throw PlayerDataError.requestFailed }
        saved = profile
        return saved
    }
    func submit(_ result: SavedJugglingResult) async throws { }
    func history(userID: UUID, before: SessionHistoryCursor?) async throws -> SessionHistoryPage { .init(items: [], next: nil) }
    func leaderboard(period: String, country: String?, userID: UUID?) async throws -> JugglingLeaderboard { .init(entries: [], aroundMe: [], totalPlayers: 0) }
    func avatarURL(path: String, userID: UUID?) async throws -> URL { throw PlayerDataError.unavailable }
    func uploadAvatar(_ jpeg: Data, userID: UUID) async throws { throw PlayerDataError.unavailable }
    func deleteAvatar(userID: UUID) async throws { throw PlayerDataError.unavailable }
}
#endif
