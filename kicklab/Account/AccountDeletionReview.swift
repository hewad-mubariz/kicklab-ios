#if DEBUG
import Foundation

/// Isolated UI-test fixture: no real account, cloud calls, or production history.
enum AccountDeletionReview {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--account-deletion-review") }
    static func account() -> AccountStore { AccountStore(service: ReviewService()) }
    static func player() -> PlayerStore {
        PlayerStore(service: nil, queue: .init(root: .temporaryDirectory.appendingPathComponent("JuggleDudeDeletionReview-" + UUID().uuidString)))
    }
}

@MainActor
private final class ReviewService: AccountAuthService {
    let identity = AccountIdentity(id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                                   email: "review@example.test", name: "Review player")
    var changes: AsyncStream<AccountIdentity?> {
        AsyncStream { $0.yield(identity); $0.finish() }
    }
    func google() async throws -> AccountIdentity { identity }
    func apple() async throws -> AccountIdentity { identity }
    func sendLink(email: String) async throws { throw AccountDeletionFailure.failed }
    func callback(_ url: URL) async throws -> AccountIdentity { throw AccountDeletionFailure.failed }
    func signOut() async throws { }
    func setActive(_ active: Bool) async { }
    func deleteAccount(userID: UUID) async throws {
        guard userID == identity.id else { throw AccountDeletionFailure.signIn }
        try await Task.sleep(for: .milliseconds(200))
        if ProcessInfo.processInfo.arguments.contains("--account-deletion-failure") { throw AccountDeletionFailure.failed }
    }
}
#endif
