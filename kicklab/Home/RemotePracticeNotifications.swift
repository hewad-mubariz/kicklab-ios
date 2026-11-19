import Combine
import Foundation
import UIKit
import UserNotifications

@MainActor
protocol RemotePushPlatform {
    func authorization() async -> UNAuthorizationStatus
    func clearLocalReminders() async throws
    func register()
}

@MainActor
private struct SystemRemotePushPlatform: RemotePushPlatform {
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func clearLocalReminders() async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: PracticeNotifications.managedReminderIdentifiers)
        let remaining = await center.pendingNotificationRequests()
        guard !remaining.contains(where: { PracticeNotifications.managedReminderIdentifiers.contains($0.identifier) }) else {
            throw PushRegistrationError.unavailable
        }
    }
    func register() { UIApplication.shared.registerForRemoteNotifications() }
}

/// Guests authenticate an installation with a device-only Keychain capability.
/// Account binding is optional; the server verifies the account JWT itself.
@MainActor
final class RemotePracticeNotifications: ObservableObject {
    static let legacyEnabledKey = "juggledude.notifications.remote-training"
    static let category = "training-invite"
    static let shared = RemotePracticeNotifications(defaults: .standard,
        vault: KeychainPushInstallationVault(),
        client: (try? AccountConfiguration.load()).map { HTTPPushRegistrationClient(configuration: $0) },
        platform: SystemRemotePushPlatform())
    @Published private(set) var enabled: Bool
    @Published private(set) var leaderboardEnabled: Bool
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
    private var requestsRegistration = false

    init(defaults: UserDefaults, vault: any PushInstallationVault,
         client: (any PushRegistrationClient)?, platform: any RemotePushPlatform) {
        self.defaults = defaults; self.vault = vault; self.client = client; self.platform = platform
        enabled = defaults.bool(forKey: PracticeNotifications.enabledKey)
        leaderboardEnabled = defaults.bool(forKey: PracticeNotifications.leaderboardKey)
        defaults.removeObject(forKey: Self.legacyEnabledKey)
    }

    func useAccount(_ account: AccountStore) async {
        self.account = account
        await refresh()
    }
    func refresh() async {
        enabled = defaults.bool(forKey: PracticeNotifications.enabledKey)
        leaderboardEnabled = defaults.bool(forKey: PracticeNotifications.leaderboardKey)
        await synchronize(register: enabled || leaderboardEnabled)
    }
    func receivedToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        registeredWithApple = true
        Task { await synchronize(register: false) }
    }
    func registrationFailed() {
        registeredWithApple = false; synchronized = false
        errorMessage = String(localized: "Couldn’t connect push notifications. Try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
    /// Account deletion must not silently re-enrol the installation as a guest.
    func accountWasDeleted() async {
        defaults.set(false, forKey: PracticeNotifications.enabledKey)
        defaults.set(false, forKey: PracticeNotifications.leaderboardKey)
        await refresh()
    }

    private var reminderMinute: Int {
        let value = defaults.object(forKey: PracticeNotifications.timeKey) as? Int
        return value.flatMap { (0..<1440).contains($0) ? $0 : nil } ?? 18 * 60
    }

    private func synchronize(register: Bool) async {
        needsSync = true
        requestsRegistration = requestsRegistration || register
        if let worker { await worker.value; return }
        isUpdating = true
        let task = Task { @MainActor in
            defer { self.worker = nil; self.isUpdating = false }
            while self.needsSync {
                self.needsSync = false
                let register = self.requestsRegistration; self.requestsRegistration = false
                self.errorMessage = nil; self.synchronized = false
                do {
                    self.enabled = self.defaults.bool(forKey: PracticeNotifications.enabledKey)
                    self.leaderboardEnabled = self.defaults.bool(forKey: PracticeNotifications.leaderboardKey)
                    let wantsPractice = self.enabled, wantsLeaderboard = self.leaderboardEnabled
                    let permission = await self.platform.authorization()
                    try await self.platform.clearLocalReminders()
                    let permitted = PracticeNotifications.allows(permission)
                    let allowed = (wantsPractice || wantsLeaderboard) && permitted
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
                    guard wantsPractice == self.defaults.bool(forKey: PracticeNotifications.enabledKey),
                          wantsLeaderboard == self.defaults.bool(forKey: PracticeNotifications.leaderboardKey),
                          userID == self.account?.user?.id else { self.needsSync = true; continue }
                    #if DEBUG
                    let environment = "sandbox"
                    #else
                    let environment = "production"
                    #endif
                    try await client.synchronize(PushRegistration(installationId: current.id,
                        secret: current.secret, revision: current.revision,
                        bundleId: Bundle.main.bundleIdentifier ?? "com.juggledude", environment: environment,
                        token: allowed ? self.deviceToken : nil, trainingEnabled: wantsPractice && permitted,
                        leaderboardEnabled: wantsLeaderboard && permitted,
                        dailyReminderEnabled: false,
                        locale: AppLanguage.current,
                        reminderMinute: self.reminderMinute,
                        timeZone: TimeZone.autoupdatingCurrent.identifier), accessToken: accessToken)
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
final class AppNotificationNavigation: ObservableObject {
    static let shared = AppNotificationNavigation()
    static let leaderboardCategory = "leaderboard-update"
    enum Destination: Equatable { case practice, leaderboard }
    struct Request: Equatable {
        let id = UUID()
        let destination: Destination
    }
    @Published private(set) var pending: Request?
    @discardableResult
    func receive(category: String, action: String) -> Bool {
        guard action == UNNotificationDefaultActionIdentifier else { return false }
        let destination: Destination
        switch category {
        case PracticeNotifications.reminderCategory, RemotePracticeNotifications.category: destination = .practice
        case Self.leaderboardCategory: destination = .leaderboard
        default: return false
        }
        pending = Request(destination: destination)
        return true
    }
    func consume() { pending = nil }
    /// "Start juggling" from the widget, a quick action, Siri or a shortcut.
    func requestPractice() { pending = Request(destination: .practice) }
}
