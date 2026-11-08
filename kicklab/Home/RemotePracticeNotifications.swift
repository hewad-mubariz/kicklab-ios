import Combine
import Foundation
import UIKit
import UserNotifications

@MainActor
protocol RemotePushPlatform {
    func authorization() async -> UNAuthorizationStatus
    func requestPermission() async throws
    func register()
}

@MainActor
private struct SystemRemotePushPlatform: RemotePushPlatform {
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func requestPermission() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func register() { UIApplication.shared.registerForRemoteNotifications() }
}

/// Guests authenticate an installation with a device-only Keychain capability.
/// Account binding is optional; the server verifies the account JWT itself.
@MainActor
final class RemotePracticeNotifications: ObservableObject {
    static let enabledKey = "juggledude.notifications.remote-training"
    static let category = "training-invite"
    static let shared = RemotePracticeNotifications(defaults: .standard,
        vault: KeychainPushInstallationVault(),
        client: (try? AccountConfiguration.load()).map { HTTPPushRegistrationClient(configuration: $0) },
        platform: SystemRemotePushPlatform())
    @Published private(set) var enabled: Bool
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var registeredWithApple = false
    @Published private(set) var synchronized = false
    @Published private(set) var installationID: UUID?
    private let defaults: UserDefaults
    private let vault: any PushInstallationVault
    private let client: (any PushRegistrationClient)?
    private let platform: any RemotePushPlatform
    private weak var account: AccountStore?
    private var deviceToken: String?
    private var worker: Task<Void, Never>?
    private var needsSync = false
    private var asksPermission = false
    private var requestsRegistration = false

    init(defaults: UserDefaults, vault: any PushInstallationVault,
         client: (any PushRegistrationClient)?, platform: any RemotePushPlatform) {
        self.defaults = defaults; self.vault = vault; self.client = client; self.platform = platform
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    func useAccount(_ account: AccountStore) async {
        self.account = account
        await refresh()
    }
    func setEnabled(_ value: Bool) async {
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        await synchronize(ask: value, register: value)
    }
    func refresh() async { await synchronize(ask: false, register: enabled) }
    func receivedToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        registeredWithApple = true
        Task { await synchronize(ask: false, register: false) }
    }
    func registrationFailed() {
        registeredWithApple = false; synchronized = false
        errorMessage = String(localized: "Couldn’t connect push notifications. Try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
    /// Account deletion must not silently re-enrol the installation as a guest.
    func accountWasDeleted() async { await setEnabled(false) }

    private func synchronize(ask: Bool, register: Bool) async {
        needsSync = true; asksPermission = asksPermission || ask
        requestsRegistration = requestsRegistration || register
        if let worker { await worker.value; return }
        isUpdating = true
        let task = Task { @MainActor in
            defer { self.worker = nil; self.isUpdating = false }
            while self.needsSync {
                self.needsSync = false
                let ask = self.asksPermission; self.asksPermission = false
                let register = self.requestsRegistration; self.requestsRegistration = false
                self.errorMessage = nil; self.synchronized = false
                do {
                    var permission = await self.platform.authorization()
                    if ask, self.enabled, permission == .notDetermined {
                        try await self.platform.requestPermission()
                        permission = await self.platform.authorization()
                    }
                    let allowed = self.enabled && PracticeNotifications.allows(permission)
                    if allowed, register { self.platform.register() }
                    var credential = try self.vault.load()
                    if allowed && self.deviceToken == nil { continue }
                    // An installation that never opted in creates no server record.
                    if !allowed && credential == nil { self.synchronized = true; continue }
                    guard let client = self.client else { throw PushRegistrationError.unavailable }
                    if credential == nil { credential = try KeychainPushInstallationVault.create() }
                    guard var current = credential, current.revision < Int64.max else { throw PushRegistrationError.storage }
                    current.revision += 1
                    // Persist the sequence before sending. An old request surviving
                    // process termination cannot overwrite a newer opt-out/login.
                    try self.vault.save(current)
                    self.installationID = current.id
                    let userID = self.account?.user?.id
                    let accessToken: String?
                    if allowed, let userID, let account = self.account {
                        accessToken = try await account.accessToken(for: userID)
                    } else { accessToken = nil }
                    guard allowed == (self.enabled && PracticeNotifications.allows(permission)),
                          userID == self.account?.user?.id else { self.needsSync = true; continue }
                    #if DEBUG
                    let environment = "sandbox"
                    #else
                    let environment = "production"
                    #endif
                    try await client.synchronize(PushRegistration(installationId: current.id,
                        secret: current.secret, revision: current.revision,
                        bundleId: Bundle.main.bundleIdentifier ?? "com.juggledude", environment: environment,
                        token: allowed ? self.deviceToken : nil, trainingEnabled: allowed,
                        dailyReminderEnabled: self.defaults.bool(forKey: PracticeNotifications.dailyKey),
                        locale: AppLanguage.current), accessToken: accessToken)
                    self.synchronized = !self.needsSync
                } catch {
                    self.errorMessage = String(localized: "Your notification choice is saved on this phone. Connect and retry to update push messages.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                }
            }
        }
        worker = task
        await task.value
    }
}

@MainActor
final class PracticeNotificationNavigation: ObservableObject {
    static let shared = PracticeNotificationNavigation()
    @Published private(set) var pending: UUID?
    func openPractice() { pending = UUID() }
    func consume() { pending = nil }
}
