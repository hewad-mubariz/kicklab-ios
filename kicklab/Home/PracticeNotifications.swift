import Combine
import Foundation
import UserNotifications

@MainActor
protocol PracticeNotificationClient {
    func authorization() async -> UNAuthorizationStatus
    func requestPermission() async throws
    func setReminders(_ requests: [UNNotificationRequest]) async throws
}

@MainActor
private struct SystemPracticeNotifications: PracticeNotificationClient {
    func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func requestPermission() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func setReminders(_ requests: [UNNotificationRequest]) async throws {
        let center = UNUserNotificationCenter.current()
        // Also remove the previous daily schedule when upgrading an existing install.
        let identifiers = PracticeNotifications.managedReminderIdentifiers
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        do {
            for request in requests { try await center.add(request) }
        } catch {
            // A failed update must not leave only part of the weekly schedule active.
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            throw error
        }
    }
}

/// Practice and leaderboard preferences sync to the server; exports remain local. Reconciliation is serialized
/// so a slow permission response cannot restore a reminder the user switched off.
@MainActor
final class PracticeNotifications: ObservableObject {
    static let shared = PracticeNotifications(defaults: .standard, client: SystemPracticeNotifications())
    static let legacyReminderIdentifier = "juggledude.daily-practice"
    // Keep the category and stored preference compatible with earlier 1.2 builds.
    static let reminderCategory = "daily-practice"
    static let enabledKey = "juggledude.notifications.daily"
    // Calendar weekday values: Sunday = 1, Monday = 2, Wednesday = 4.
    static let reminderWeekdays = [2, 4, 1]
    static let reminderIdentifiers = reminderWeekdays.map { "juggledude.practice.weekday-\($0)" }
    static let managedReminderIdentifiers = [legacyReminderIdentifier] + reminderIdentifiers
    static let exportsKey = "juggledude.notifications.exports"
    static let leaderboardKey = "juggledude.notifications.leaderboard"
    static let timeKey = "juggledude.notifications.minute-of-day"
    static let completedSessionKey = "juggledude.notifications.session-completed"
    static let sessionPromptHandledKey = "juggledude.notifications.session-prompt-handled"

    @Published private(set) var practiceEnabled: Bool
    @Published private(set) var exportsEnabled: Bool
    @Published private(set) var leaderboardEnabled: Bool
    @Published private(set) var minuteOfDay: Int
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasCompletedSession: Bool
    @Published private(set) var sessionPromptHandled: Bool
    @Published private(set) var isRequestingSessionPermission = false
    @Published private(set) var presentedSessionPromptThisLaunch = false
    private let defaults: UserDefaults
    private let client: any PracticeNotificationClient
    private var worker: Task<Void, Never>?
    private var needsSync = false
    private var asksPermission = false

    init(defaults: UserDefaults, client: any PracticeNotificationClient) {
        self.defaults = defaults; self.client = client
        practiceEnabled = defaults.bool(forKey: Self.enabledKey)
        exportsEnabled = defaults.bool(forKey: Self.exportsKey)
        leaderboardEnabled = defaults.bool(forKey: Self.leaderboardKey)
        hasCompletedSession = defaults.bool(forKey: Self.completedSessionKey)
        sessionPromptHandled = defaults.bool(forKey: Self.sessionPromptHandledKey)
        let saved = defaults.object(forKey: Self.timeKey) as? Int
        minuteOfDay = saved.flatMap { (0..<1440).contains($0) ? $0 : nil } ?? 18 * 60
    }

    var isAllowed: Bool { Self.allows(authorization) }
    static func allows(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }

    var shouldAskAfterSession: Bool {
        hasCompletedSession && !sessionPromptHandled && defaults.object(forKey: Self.enabledKey) == nil
    }

    /// Completion only makes the question eligible. Home presents it after the replay closes.
    func sessionCompleted() {
        guard !hasCompletedSession else { return }
        defaults.set(true, forKey: Self.completedSessionKey)
        hasCompletedSession = true
    }

    func requestAfterSessionIfNeeded() async {
        guard shouldAskAfterSession, !isRequestingSessionPermission else { return }
        isRequestingSessionPermission = true
        defer { isRequestingSessionPermission = false }
        // Let an explicit Settings choice finish before considering the automatic prompt.
        if let worker { await worker.value }
        guard !Task.isCancelled, shouldAskAfterSession else { return }
        authorization = await client.authorization()
        guard !Task.isCancelled, shouldAskAfterSession else { return }
        defaults.set(true, forKey: Self.sessionPromptHandledKey)
        sessionPromptHandled = true
        // A previous permission decision (for example, exports) is not a new practice opt-in.
        guard authorization == .notDetermined else { return }
        presentedSessionPromptThisLaunch = true
        do {
            try await client.requestPermission()
            authorization = await client.authorization()
            // A manual opt-out/account deletion while the dialog was open must win.
            if defaults.object(forKey: Self.enabledKey) == nil {
                defaults.set(isAllowed, forKey: Self.enabledKey)
                practiceEnabled = isAllowed
            }
            // Record the OS answer even if its modal transition cancelled the Home task.
            await refresh()
        } catch {
            errorMessage = String(localized: "Couldn’t update notifications. Try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }

    func setPracticeEnabled(_ value: Bool) async {
        practiceEnabled = value; defaults.set(value, forKey: Self.enabledKey)
        await synchronize(askPermission: value)
    }

    func setExportsEnabled(_ value: Bool) async {
        exportsEnabled = value; defaults.set(value, forKey: Self.exportsKey)
        await synchronize(askPermission: value)
    }

    func setLeaderboardEnabled(_ value: Bool) async {
        leaderboardEnabled = value; defaults.set(value, forKey: Self.leaderboardKey)
        await synchronize(askPermission: value)
    }

    func setTime(hour: Int, minute: Int) async {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return }
        minuteOfDay = hour * 60 + minute; defaults.set(minuteOfDay, forKey: Self.timeKey)
        await synchronize(askPermission: false)
    }

    /// Ordinary refreshes never prompt; only Settings or the first-session flow may ask.
    func refresh() async {
        practiceEnabled = defaults.bool(forKey: Self.enabledKey)
        leaderboardEnabled = defaults.bool(forKey: Self.leaderboardKey)
        await synchronize(askPermission: false)
    }

    #if DEBUG
    /// Legacy schedule fixture for migration checks; production delivery is remote.
    static func reminders(minuteOfDay: Int) -> [UNNotificationRequest] {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time for your 3-minute juggle", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        content.body = String(localized: "Grab your ball for a short practice session.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        content.sound = .default
        content.categoryIdentifier = reminderCategory
        // No date or time zone: each weekday repeats at the phone's local time.
        return zip(reminderWeekdays, reminderIdentifiers).map { weekday, identifier in
            var components = DateComponents()
            components.weekday = weekday
            components.hour = minuteOfDay / 60; components.minute = minuteOfDay % 60
            return UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
        }
    }

    #endif

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
                    if ask, self.practiceEnabled || self.exportsEnabled || self.leaderboardEnabled, self.authorization == .notDetermined {
                        try await self.client.requestPermission()
                        self.authorization = await self.client.authorization()
                    }
                    // Upgrading or opting out clears every previous local schedule.
                    // The backend is the sole sender for practice reminders.
                    try await self.client.setReminders([])
                } catch {
                    self.errorMessage = String(localized: "Couldn’t update notifications. Try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                }
            }
        }
        worker = task
        await task.value
    }
}
