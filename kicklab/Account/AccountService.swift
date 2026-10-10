import Auth
import Foundation

struct AccountIdentity: Equatable, Sendable {
    let id: UUID
    let email: String?
    let name: String?
}

@MainActor
protocol AccountAuthService: AnyObject {
    var changes: AsyncStream<AccountIdentity?> { get }
    func google() async throws -> AccountIdentity
    func apple() async throws -> AccountIdentity
    func sendLink(email: String) async throws
    func callback(_ url: URL) async throws -> AccountIdentity
    func signOut() async throws
    func deleteAccount(userID: UUID) async throws
    func setActive(_ active: Bool) async
    func accessToken(for userID: UUID) async throws -> String
}

extension AccountAuthService {
    func accessToken(for userID: UUID) async throws -> String { throw PlayerDataError.signIn }
    func deleteAccount(userID: UUID) async throws { throw AccountDeletionFailure.failed }
}

@MainActor
final class SupabaseAccountService: AccountAuthService {
    private let client: AuthClient
    private let configuration: AccountConfiguration
    private let browser = BrowserSignIn()
    private let appleSignIn = NativeAppleSignIn()

    init(configuration: AccountConfiguration) {
        self.configuration = configuration
        client = AuthClient(configuration: .init(
            url: configuration.projectURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": configuration.publishableKey],
            flowType: .pkce,
            redirectToURL: configuration.redirectURL,
            storageKey: "juggledude.\(configuration.projectURL.host ?? "auth").session",
            localStorage: KeychainLocalStorage(service: "juggledude.auth"),
            autoRefreshToken: true,
            emitLocalSessionAsInitialSession: true
        ))
    }

    var changes: AsyncStream<AccountIdentity?> {
        let client = client
        let events = client.authStateChanges
        return AsyncStream { continuation in
            let task = Task {
                for await (_, session) in events {
                    guard !Task.isCancelled else { break }
                    // Never present an expired stored session as a completed sign-in.
                    // The SDK serializes refreshes and persists the renewed token in Keychain.
                    let usableSession: Session?
                    if let session, session.isExpired {
                        usableSession = try? await client.session
                    } else { usableSession = session }
                    continuation.yield(usableSession.map { Self.identity($0.user) })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func google() async throws -> AccountIdentity {
        let session = try await client.signInWithOAuth(provider: .google, redirectTo: configuration.redirectURL,
                                                       scopes: "openid email profile") { [browser] url in
            try await browser.authenticate(url: url)
        }
        return Self.identity(session.user)
    }

    func apple() async throws -> AccountIdentity {
        let result = try await appleSignIn.signIn()
        let session = try await client.signInWithIdToken(credentials: .init(provider: .apple, idToken: result.idToken, nonce: result.nonce))
        // Apple shares the full name once. Preserve it in the account, not a device-wide guest name.
        if let name = result.fullName, !name.isEmpty {
            if let user = try? await client.update(user: UserAttributes(data: ["full_name": .string(name)])) {
                return Self.identity(user)
            }
        }
        return Self.identity(session.user)
    }

    func sendLink(email: String) async throws {
        try await client.signInWithOTP(email: email, redirectTo: configuration.redirectURL, shouldCreateUser: true)
    }

    func callback(_ url: URL) async throws -> AccountIdentity {
        let callback: URL
        if AccountEmailLink.matchesEndpoint(url) {
            callback = try await AccountEmailLink(url: url).resolve(configuration: configuration)
        } else {
            guard AccountConfiguration.acceptsCallback(url) else { throw AccountFailure.invalidCallback }
            callback = url
        }
        return Self.identity(try await client.session(from: callback).user)
    }

    func signOut() async throws { try await client.signOut(scope: .local) }

    func deleteAccount(userID: UUID) async throws {
        let session = try await client.session
        guard session.user.id == userID else { throw AccountDeletionFailure.signIn }
        let api = AccountDeletionAPI(configuration: configuration)
        let status = try await api.prepare(token: session.accessToken, userID: userID)
        if !status.deleted {
            var appleCode: String?
            if status.requiresApple {
                // Obtain a fresh one-use code without signing into/replacing the Supabase session.
                let result = try await appleSignIn.signIn(requestScopes: false)
                guard let code = result.authorizationCode, !code.isEmpty else {
                    throw AccountDeletionFailure.appleConfirmation
                }
                appleCode = code
            }
            guard client.currentSession?.user.id == userID else { throw AccountDeletionFailure.signIn }
            try await api.delete(token: session.accessToken, userID: userID, appleCode: appleCode)
        }
        // AuthClient clears Keychain and emits signedOut before its logout network call.
        // A network error after confirmed deletion must not resurrect the deleted account.
        try? await client.signOut(scope: .local)
    }
    func accessToken(for userID: UUID) async throws -> String {
        let session = try await client.session
        guard session.user.id == userID else { throw PlayerDataError.signIn }
        return session.accessToken
    }
    func setActive(_ active: Bool) async {
        if active { await client.startAutoRefresh() }
        else { await client.stopAutoRefresh() }
    }

    private static func identity(_ user: User) -> AccountIdentity {
        AccountIdentity(id: user.id, email: user.email,
                        name: user.userMetadata["full_name"]?.stringValue ?? user.userMetadata["name"]?.stringValue)
    }
}
