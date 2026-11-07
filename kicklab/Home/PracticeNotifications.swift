import Combine
import Foundation
import UserNotifications

@MainActor
protocol PracticeNotificationClient {
    func authorization() async -> UNAuthorizationStatus
    func requestPermission() async throws
    func setReminder(_ request: UNNotificationRequest?) async throws
}

@MainActor
private struct SystemPracticeNotifications: PracticeNotificationClient {
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func requestPermission() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func setReminder(_ request: UNNotificationRequest?) async throws {
        let center = UNUserNotificationCenter.current()
        if let request { try await center.add(request) }
        else { center.removePendingNotificationRequests(withIdentifiers: [PracticeNotifications.reminderIdentifier]) }
    }
}

/// Preferences are opt-in and local to this device. Reconciliation is serialized
/// so a slow permission response cannot restore a reminder the user switched off.
@MainActor
final class PracticeNotifications: ObservableObject {
    static let shared = PracticeNotifications(defaults: .standard, client: SystemPracticeNotifications())
    static let reminderIdentifier = "juggledude.daily-practice"
    static let reminderCategory = "daily-practice"
    static let dailyKey = "juggledude.notifications.daily"
    static let exportsKey = "juggledude.notifications.exports"
    static let timeKey = "juggledude.notifications.minute-of-day"

    @Published private(set) var dailyEnabled: Bool
    @Published private(set) var exportsEnabled: Bool
    @Published private(set) var minuteOfDay: Int
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let client: any PracticeNotificationClient
    private var worker: Task<Void, Never>?
    private var needsSync = false
    private var asksPermission = false

    init(defaults: UserDefaults, client: any PracticeNotificationClient) {
        self.defaults = defaults; self.client = client
        dailyEnabled = defaults.bool(forKey: Self.dailyKey)
        exportsEnabled = defaults.bool(forKey: Self.exportsKey)
        let saved = defaults.object(forKey: Self.timeKey) as? Int
        minuteOfDay = saved.flatMap { (0..<1440).contains($0) ? $0 : nil } ?? 18 * 60
    }

    var isAllowed: Bool { Self.allows(authorization) }
    static func allows(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }

    func setDailyEnabled(_ value: Bool) async {
        dailyEnabled = value; defaults.set(value, forKey: Self.dailyKey)
        await synchronize(askPermission: value)
    }

    func setExportsEnabled(_ value: Bool) async {
        exportsEnabled = value; defaults.set(value, forKey: Self.exportsKey)
        await synchronize(askPermission: value)
    }

    func setTime(hour: Int, minute: Int) async {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return }
        minuteOfDay = hour * 60 + minute; defaults.set(minuteOfDay, forKey: Self.timeKey)
        await synchronize(askPermission: false)
    }

    /// Opening the app, changing language or returning from Settings never prompts.
    func refresh() async { await synchronize(askPermission: false) }

    static func reminder(minuteOfDay: Int) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time for your 3-minute juggle", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        content.body = String(localized: "Grab your ball for a short practice session.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        content.sound = .default
        content.categoryIdentifier = reminderCategory
        // Hour/minute only: follows the phone's local time rather than pinning
        // the reminder to the time zone in which it was first enabled.
        var components = DateComponents()
        components.hour = minuteOfDay / 60; components.minute = minuteOfDay % 60
        return UNNotificationRequest(identifier: reminderIdentifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
    }

    private func synchronize(askPermission: Bool) async {
        needsSync = true; asksPermission = asksPermission || askPermission
        if let worker { await worker.value; return }
        isUpdating = true
        let task = Task { @MainActor in
            defer { self.worker = nil; self.isUpdating = false }
            while self.needsSync {
                self.needsSync = false
                let ask = self.asksPermission; self.asksPermission = false
                self.errorMessage = nil
                do {
                    self.authorization = await self.client.authorization()
                    if ask, self.dailyEnabled || self.exportsEnabled, self.authorization == .notDetermined {
                        try await self.client.requestPermission()
                        self.authorization = await self.client.authorization()
                    }
                    let request = self.dailyEnabled && self.isAllowed ? Self.reminder(minuteOfDay: self.minuteOfDay) : nil
                    try await self.client.setReminder(request)
                } catch {
                    self.errorMessage = String(localized: "Couldn’t update notifications. Try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                }
            }
        }
        worker = task
        await task.value
    }
}
