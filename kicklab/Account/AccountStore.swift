import Auth
import AuthenticationServices
import Combine
import Foundation

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var user: AccountIdentity?
    @Published private(set) var isRestoring = true
    @Published private(set) var isBusy = false
    @Published private(set) var isDeleting = false
    @Published private(set) var pendingEmail: String?
    @Published private(set) var resendAfter: Date = .distantPast
    @Published var errorMessage: String?
    private let service: (any AccountAuthService)?
    private var observation: Task<Void, Never>?
    private var completedCallbacks = Set<URL>()
    private var handlingCallback = false
    private var deletedUserIDs = Set<UUID>()

    init(service: (any AccountAuthService)?) {
        self.service = service
        guard let service else { isRestoring = false; return }
        let changes = service.changes
        observation = Task { [weak self] in
            for await user in changes {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let user, self.deletedUserIDs.contains(user.id) { continue }
                self.user = user
                self.isRestoring = false
                if user != nil { self.pendingEmail = nil }
            }
        }
    }

    deinit { observation?.cancel() }

    static func live() -> AccountStore {
        guard let configuration = try? AccountConfiguration.load() else { return AccountStore(service: nil) }
        return AccountStore(service: SupabaseAccountService(configuration: configuration))
    }

    func signIn(_ provider: SignInProvider) async {
        guard !isBusy else { return }
        guard let service else { errorMessage = AccountFailure.configuration.localizedDescription; return }
        guard provider != .email else { return }
        errorMessage = nil; isBusy = true
        ProductAnalytics.shared.track(.signInStarted(provider))
        defer { isBusy = false }
        do {
            switch provider {
            case .google: user = try await service.google()
            case .apple: user = try await service.apple()
            case .email: return
            }
            pendingEmail = nil
            ProductAnalytics.shared.track(.signInFinished(provider, .completed))
        } catch {
            ProductAnalytics.shared.track(.signInFinished(provider, Self.analyticsOutcome(error)))
            report(error)
        }
    }

    @discardableResult
    func sendEmailLink(to value: String) async -> Bool {
        guard !isBusy else { return false }
        guard let service else { errorMessage = AccountFailure.configuration.localizedDescription; return false }
        guard let email = AccountConfiguration.normalizedEmail(value) else { errorMessage = AccountFailure.invalidEmail.localizedDescription; return false }
        guard Date() >= resendAfter else { return false }
        errorMessage = nil; isBusy = true
        defer { isBusy = false }
        do {
            try await service.sendLink(email: email)
            pendingEmail = email
            resendAfter = Date().addingTimeInterval(60)
            ProductAnalytics.shared.track(.emailLinkRequested(.completed))
            return true
        } catch {
            ProductAnalytics.shared.track(.emailLinkRequested(Self.analyticsOutcome(error)))
            report(error); return false
        }
    }

    func handleCallback(_ url: URL) async {
        guard AccountConfiguration.acceptsIncomingLink(url), !completedCallbacks.contains(url), !handlingCallback else { return }
        // The browser flow consumes its own callback. Email callbacks arrive through onOpenURL.
        guard !isBusy else { return }
        guard let service else { errorMessage = AccountFailure.configuration.localizedDescription; return }
        isBusy = true; handlingCallback = true; errorMessage = nil
        ProductAnalytics.shared.track(.signInStarted(.email))
        defer { isBusy = false; handlingCallback = false }
        do {
            user = try await service.callback(url)
            completedCallbacks.insert(url)
            pendingEmail = nil
            ProductAnalytics.shared.track(.signInFinished(.email, .completed))
        } catch {
            ProductAnalytics.shared.track(.signInFinished(.email, Self.analyticsOutcome(error)))
            report(error, callback: true)
        }
    }

    func signOut() async {
        guard !isBusy, let service else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.signOut()
            user = nil; pendingEmail = nil
            ProductAnalytics.shared.resetIdentity()
        } catch { report(error) }
    }

    @discardableResult
    func deleteAccount(cleanup: (UUID) async -> Bool) async -> Bool {
        guard !isBusy, let id = user?.id, let service else { return false }
        isBusy = true; isDeleting = true; errorMessage = nil
        defer { isBusy = false; isDeleting = false }
        do {
            try await service.deleteAccount(userID: id)
            ProductAnalytics.shared.resetIdentity()
            deletedUserIDs.insert(id)
            user = nil; pendingEmail = nil; resendAfter = .distantPast
            completedCallbacks.removeAll()
            if !(await cleanup(id)) {
                errorMessage = "Your account was deleted. Some local replays couldn’t be removed yet; Juggle Dude will retry when you reopen it."
            }
            return true
        } catch {
            if error is CancellationError { return false }
            if let error = error as? ASAuthorizationError, error.code == .canceled { return false }
            if let error = error as? URLError, error.code == .notConnectedToInternet {
                errorMessage = "You’re offline. Connect to the internet to delete your account."
            } else {
                errorMessage = (error as? AccountDeletionFailure)?.localizedDescription
                    ?? AccountDeletionFailure.failed.localizedDescription
            }
            return false
        }
    }

    func setActive(_ active: Bool) async { await service?.setActive(active) }

    func accessToken(for userID: UUID) async throws -> String {
        guard user?.id == userID, let service else { throw PlayerDataError.signIn }
        let token = try await service.accessToken(for: userID)
        guard user?.id == userID else { throw PlayerDataError.signIn }
        return token
    }

    private static func analyticsOutcome(_ error: Error) -> ProductEvent.Outcome {
        if error is CancellationError { return .cancelled }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return .cancelled }
        if let error = error as? ASAuthorizationError, error.code == .canceled { return .cancelled }
        return .failed
    }

    private func report(_ error: Error, callback: Bool = false) {
        if error is CancellationError { return }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return }
        if let error = error as? ASAuthorizationError, error.code == .canceled { return }
        if let failure = error as? AccountFailure { errorMessage = failure.localizedDescription; return }
        if let network = error as? URLError {
            errorMessage = network.code == .notConnectedToInternet
                ? "You’re offline. Connect to the internet and try again."
                : "We couldn’t reach sign-in. Please try again."
            return
        }
        if callback {
            errorMessage = "This link has expired or was opened on a different device. Request a new link here and open it on this device."
        } else if let auth = error as? AuthError, auth.errorCode.rawValue == "over_email_send_rate_limit" || auth.errorCode.rawValue == "over_request_rate_limit" {
            resendAfter = Date().addingTimeInterval(60)
            errorMessage = "Too many attempts. Wait a minute, then try again."
        } else if let auth = error as? AuthError, auth.errorCode == .emailAddressNotAuthorized {
            errorMessage = "Email sign-in isn’t available for this address yet. Please use Google or Apple for now."
        } else if let auth = error as? AuthError, auth.errorCode == .providerDisabled {
            errorMessage = "This sign-in option is temporarily unavailable. Please choose another option."
        } else {
            // SDK errors can include callback URLs and tokens. Never display or log raw errors.
            errorMessage = "Sign-in couldn’t be completed. Please try again."
        }
    }
}
