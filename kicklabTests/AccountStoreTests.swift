import AuthenticationServices
import XCTest
@testable import kicklab

@MainActor
final class AccountStoreTests: XCTestCase {
    func testConfigurationRejectsSecretKeysAndUnexpectedCallbackTargets() throws {
        var values = ["SUPABASE_URL": "https://example.supabase.co", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test", "AUTH_REDIRECT_URL": "juggledude://auth/callback"]
        XCTAssertNoThrow(try AccountConfiguration(values: values))
        values["SUPABASE_PUBLISHABLE_KEY"] = "sb_secret_test"
        XCTAssertThrowsError(try AccountConfiguration(values: values))
        values["SUPABASE_PUBLISHABLE_KEY"] = "sb_publishable_test"
        values["AUTH_REDIRECT_URL"] = "juggledude://untrusted/callback"
        XCTAssertThrowsError(try AccountConfiguration(values: values))
        for url in ["https://auth/callback?code=a", "juggledude://evil/callback?code=a", "juggledude://auth/other?code=a", "juggledude://user@auth/callback?code=a", "juggledude://auth:80/callback?code=a"] {
            XCTAssertFalse(AccountConfiguration.acceptsCallback(URL(string: url)!))
        }
        XCTAssertTrue(AccountConfiguration.acceptsCallback(URL(string: "juggledude://auth/callback?code=a")!))
    }

    func testSessionRestorationAndSignOutEventsUpdateProfile() async {
        let service = TestAccountService()
        let account = AccountStore(service: service)
        service.events.yield(service.identity)
        await settle()
        XCTAssertEqual(account.user, service.identity)
        XCTAssertFalse(account.isRestoring)
        service.events.yield(nil)
        await settle()
        XCTAssertNil(account.user)
        await account.signIn(.google)
        XCTAssertEqual(account.user, service.identity)
        await account.signOut()
        XCTAssertNil(account.user)
        XCTAssertEqual(service.signOutCalls, 1)
    }

    func testEmailValidationSuccessAndCooldown() async {
        let service = TestAccountService()
        let account = AccountStore(service: service)
        let invalid = await account.sendEmailLink(to: "not an email")
        XCTAssertFalse(invalid)
        XCTAssertTrue(service.sentEmails.isEmpty)
        let valid = await account.sendEmailLink(to: "  player@example.com \n")
        XCTAssertTrue(valid)
        XCTAssertEqual(service.sentEmails, ["player@example.com"])
        XCTAssertEqual(account.pendingEmail, "player@example.com")
        XCTAssertNil(account.user, "Sending a link is not a successful login")
        let repeated = await account.sendEmailLink(to: "player@example.com")
        XCTAssertFalse(repeated)
        XCTAssertEqual(service.sentEmails.count, 1)
        XCTAssertFalse(account.isBusy)
    }

    func testEmailFailureDoesNotShowSentOrCreateSession() async {
        let service = TestAccountService()
        service.failure = URLError(.notConnectedToInternet)
        let account = AccountStore(service: service)
        let sent = await account.sendEmailLink(to: "player@example.com")
        XCTAssertFalse(sent)
        XCTAssertNil(account.pendingEmail)
        XCTAssertNil(account.user)
        XCTAssertTrue(account.errorMessage?.contains("offline") == true)
        XCTAssertFalse(account.isBusy)
    }

    func testCallbackIgnoresOtherURLsAndConsumesSuccessOnce() async {
        let service = TestAccountService()
        let account = AccountStore(service: service)
        await account.handleCallback(URL(string: "juggledude://wrong/callback?code=test")!)
        XCTAssertEqual(service.callbackCalls, 0)
        let url = URL(string: "juggledude://auth/callback?code=test")!
        await account.handleCallback(url)
        await account.handleCallback(url)
        XCTAssertEqual(service.callbackCalls, 1)
        XCTAssertEqual(account.user, service.identity)
    }

    func testFailedCallbackDoesNotLeakCodeAndCanBeRetried() async {
        let service = TestAccountService()
        service.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "sensitive-code-in-error"])
        let account = AccountStore(service: service)
        let url = URL(string: "juggledude://auth/callback?code=sensitive-code-in-error")!
        await account.handleCallback(url)
        XCTAssertNil(account.user)
        XCTAssertFalse(account.errorMessage?.contains("sensitive-code-in-error") == true)
        XCTAssertFalse(account.isBusy)
        service.failure = nil
        await account.handleCallback(url)
        XCTAssertEqual(account.user, service.identity)
        XCTAssertNil(account.errorMessage)
    }

    func testUniversalEmailCallbackUpdatesProfileAndIsConsumedOnce() async {
        let service = TestAccountService()
        let account = AccountStore(service: service)
        let url = URL(string: "https://juggledude.com/auth/email/#token_hash=pkce_" + String(repeating: "a", count: 56) + "&type=magiclink")!
        await account.handleCallback(url)
        await account.handleCallback(url)
        XCTAssertEqual(service.callbackCalls, 1)
        XCTAssertEqual(account.user, service.identity)
        XCTAssertNil(account.pendingEmail)
    }

    func testBrowserAndAppleCancellationAreQuiet() async {
        let service = TestAccountService()
        let account = AccountStore(service: service)
        for error in [ASWebAuthenticationSessionError(.canceledLogin) as Error, ASAuthorizationError(.canceled) as Error] {
            service.failure = error
            await account.signIn(.google)
            XCTAssertNil(account.errorMessage)
            XCTAssertNil(account.user)
            XCTAssertFalse(account.isBusy)
        }
    }

    func testRepeatedSignInDoesNotStartOverlappingProviders() async {
        let service = TestAccountService()
        service.pauseGoogle = true
        let account = AccountStore(service: service)
        let first = Task { await account.signIn(.google) }
        await settle()
        XCTAssertTrue(account.isBusy)
        await account.signIn(.apple)
        XCTAssertEqual(service.appleCalls, 0)
        service.resumeGoogle?.resume()
        await first.value
        XCTAssertEqual(service.googleCalls, 1)
        XCTAssertFalse(account.isBusy)
    }

    func testMissingConfigKeepsGuestAvailableAndExplainsFailure() async {
        let account = AccountStore(service: nil)
        XCTAssertFalse(account.isRestoring)
        await account.signIn(.google)
        XCTAssertNotNil(account.errorMessage)
        XCTAssertNil(account.user)
    }

    func testAppleNonceIsSecurelyRandomAndDifferentEachTime() throws {
        let first = try NativeAppleSignIn.makeNonce()
        let second = try NativeAppleSignIn.makeNonce()
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
    }

    func testDeletionSignsOutAndCleansOnlyTheConfirmedAccount() async {
        let service = TestAccountService(), account = AccountStore(service: nil)
        let guestDeletion = await account.deleteAccount(cleanup: { _ in XCTFail("Guest cleanup"); return true })
        XCTAssertFalse(guestDeletion)
        let signedIn = AccountStore(service: service)
        await signedIn.signIn(.google)
        var cleaned: UUID?
        let deleted = await signedIn.deleteAccount { cleaned = $0; return true }
        XCTAssertTrue(deleted)
        XCTAssertEqual(service.deletedIDs, [service.identity.id])
        XCTAssertEqual(cleaned, service.identity.id)
        XCTAssertNil(signedIn.user)
        XCTAssertNil(signedIn.errorMessage)
        XCTAssertFalse(signedIn.isDeleting)
        service.events.yield(service.identity)
        await settle()
        XCTAssertNil(signedIn.user, "A stale refresh must not restore the deleted account")
    }

    func testFailedDeletionKeepsAccountAndLocalDataAndCanRetry() async {
        let service = TestAccountService()
        let signedIn = AccountStore(service: service)
        await signedIn.signIn(.google)
        service.failure = NSError(domain: "secret-token", code: 1)
        let failed = await signedIn.deleteAccount { _ in XCTFail("Must not erase local data on failure"); return true }
        XCTAssertFalse(failed)
        XCTAssertEqual(signedIn.user, service.identity)
        XCTAssertEqual(signedIn.errorMessage, AccountDeletionFailure.failed.localizedDescription)
        service.failure = nil
        let retried = await signedIn.deleteAccount { _ in true }
        XCTAssertTrue(retried)
        XCTAssertNil(signedIn.user)
    }

    func testAppleDeletionCancellationDoesNotDeleteOrShowError() async {
        let service = TestAccountService()
        let signedIn = AccountStore(service: service)
        await signedIn.signIn(.apple)
        service.failure = ASAuthorizationError(.canceled)
        let deleted = await signedIn.deleteAccount { _ in XCTFail("Cancelled cleanup"); return true }
        XCTAssertFalse(deleted)
        XCTAssertEqual(signedIn.user, service.identity)
        XCTAssertNil(signedIn.errorMessage)
    }

    func testConfirmedDeletionDoesNotPretendLocalCleanupFailureRestoredAccount() async {
        let service = TestAccountService(), account = AccountStore(service: service)
        await account.signIn(.google)
        let deleted = await account.deleteAccount { _ in false }
        XCTAssertTrue(deleted)
        XCTAssertNil(account.user)
        XCTAssertTrue(account.errorMessage?.contains("account was deleted") == true)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
private final class TestAccountService: AccountAuthService {
    let identity = AccountIdentity(id: UUID(), email: "player@example.com", name: "Player")
    let changes: AsyncStream<AccountIdentity?>
    let events: AsyncStream<AccountIdentity?>.Continuation
    var failure: Error?
    var sentEmails: [String] = []
    var googleCalls = 0
    var appleCalls = 0
    var callbackCalls = 0
    var signOutCalls = 0
    var deletedIDs: [UUID] = []
    var pauseGoogle = false
    var resumeGoogle: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream<AccountIdentity?>.makeStream()
        changes = stream.stream; events = stream.continuation
    }
    func google() async throws -> AccountIdentity {
        googleCalls += 1
        if pauseGoogle { await withCheckedContinuation { resumeGoogle = $0 } }
        if let failure { throw failure }
        return identity
    }
    func apple() async throws -> AccountIdentity {
        appleCalls += 1
        if let failure { throw failure }
        return identity
    }
    func sendLink(email: String) async throws {
        if let failure { throw failure }
        sentEmails.append(email)
    }
    func callback(_ url: URL) async throws -> AccountIdentity {
        callbackCalls += 1
        if let failure { throw failure }
        return identity
    }
    func signOut() async throws { signOutCalls += 1 }
    func deleteAccount(userID: UUID) async throws {
        if let failure { throw failure }
        deletedIDs.append(userID)
    }
    func setActive(_ active: Bool) async { }
}
