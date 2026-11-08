#if DEBUG
import SwiftUI
import UserNotifications

/// Exercises the real settings and OS scheduler on a dedicated preview install.
struct NotificationReview: View {
    /// A local fixture exercises the same category/delegate/navigation as the
    /// real APNs message, without bypassing the server's daily delivery cap.
    static func scheduleTapCheckIfRequested() async {
        let leaderboard = ProcessInfo.processInfo.arguments.contains("--leaderboard-notification-tap-review")
        guard Bundle.main.bundleIdentifier == "com.juggledude.release120.preview",
              leaderboard || ProcessInfo.processInfo.arguments.contains("--notification-tap-review") else { return }
        let center = UNUserNotificationCenter.current()
        guard PracticeNotifications.allows(await center.notificationSettings().authorizationStatus) else { return }
        let fixtures = ["juggledude.notification-tap-check", "juggledude.leaderboard-tap-check"]
        center.removePendingNotificationRequests(withIdentifiers: fixtures)
        center.removeDeliveredNotifications(withIdentifiers: fixtures)
        let content = UNMutableNotificationContent()
        content.title = leaderboard ? "Juggle Dude leaderboard tap check" : "Juggle Dude notification tap check"
        content.body = leaderboard ? "Test alert: tap to open the leaderboard." : "Test alert: tap to open juggling setup."
        content.categoryIdentifier = leaderboard ? AppNotificationNavigation.leaderboardCategory : RemotePracticeNotifications.category
        try? await center.add(UNNotificationRequest(identifier: leaderboard ? "juggledude.leaderboard-tap-check" : "juggledude.notification-tap-check",
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 8, repeats: false)))
    }
    @State private var pending = "Loading"
    @State private var delivered = "Loading"
    private static let deliveryCheckIdentifier = "juggledude.practice-delivery-check"
    @State private var practiceDelivered = "Loading"
    @State private var pushStatus = "Loading"
    var body: some View {
        NavigationStack {
            VStack {
                NotificationSettingsView()
                Text(pending).accessibilityIdentifier("notification-review-pending")
                Text(delivered).accessibilityIdentifier("notification-review-delivered")
                Text(practiceDelivered).accessibilityIdentifier("notification-review-practice-delivered")
                Text(pushStatus).font(.caption).accessibilityIdentifier("notification-review-push")
                if Bundle.main.bundleIdentifier == "com.juggledude.release120.preview" {
                    Button("Schedule a test reminder in 8 seconds") {
                        Task {
                            // Check delivery on any weekday without altering the weekly schedule.
                            guard PracticeNotifications.shared.practiceEnabled,
                                  PracticeNotifications.shared.isAllowed,
                                  let content = PracticeNotifications.reminders(minuteOfDay: 1080).first?.content else { return }
                            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
                                identifier: Self.deliveryCheckIdentifier, content: content,
                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 8, repeats: false)))
                            await inspect()
                        }
                    }.accessibilityIdentifier("notification-review-soon")
                    Button("Add legacy daily reminder for migration check") {
                        Task {
                            guard PracticeNotifications.shared.practiceEnabled,
                                  let content = PracticeNotifications.reminders(minuteOfDay: 1080).first?.content else { return }
                            let components = DateComponents(hour: 18, minute: 0)
                            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
                                identifier: PracticeNotifications.legacyReminderIdentifier, content: content,
                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)))
                            await inspect(refresh: false)
                        }
                    }.accessibilityIdentifier("notification-review-legacy")
                    Button("Restore default reminder time") {
                        Task { await PracticeNotifications.shared.setTime(hour: 18, minute: 0); await inspect() }
                    }.accessibilityIdentifier("notification-review-default-time")
                    Button("Clear delivered test reminder") {
                        let center = UNUserNotificationCenter.current()
                        center.removePendingNotificationRequests(withIdentifiers: [Self.deliveryCheckIdentifier])
                        center.removeDeliveredNotifications(withIdentifiers: PracticeNotifications.managedReminderIdentifiers + [Self.deliveryCheckIdentifier])
                        Task { await inspect(refresh: false) }
                    }.accessibilityIdentifier("notification-review-clear-practice")
                }
                Button("Refresh notification check") { Task { await inspect() } }
                    .accessibilityIdentifier("notification-review-refresh")
            }.task {
                await inspect()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await inspect(refresh: false)
                }
            }
        }
    }

    private func inspect(refresh: Bool = true) async {
        if refresh { await PracticeNotifications.shared.refresh() }
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let notifications = await center.deliveredNotifications()
        pending = "\(requests.filter { PracticeNotifications.managedReminderIdentifiers.contains($0.identifier) }.count) practice reminders"
        delivered = "\(notifications.filter { $0.request.content.categoryIdentifier == "video-saved" }.count) export alerts"
        practiceDelivered = "\(notifications.filter { $0.request.content.categoryIdentifier == PracticeNotifications.reminderCategory }.count) practice alerts"
        let remote = RemotePracticeNotifications.shared
        let pushCount = notifications.filter { $0.request.content.categoryIdentifier == RemotePracticeNotifications.category }.count
        pushStatus = "Apple: \(remote.registeredWithApple); server: \(remote.synchronized); \(pushCount) remote alerts"
        let value: [String: Any] = [
            "remote": ["enabled": remote.enabled, "apple_registered": remote.registeredWithApple,
                       "synchronized": remote.synchronized, "installation_id": remote.installationID?.uuidString ?? "none",
                       "error": remote.errorMessage ?? "none"],
            "authorization": await center.notificationSettings().authorizationStatus.rawValue,
            "pending": requests.map { request -> [String: Any] in
                let trigger = request.trigger as? UNCalendarNotificationTrigger
                return ["id": request.identifier, "title": request.content.title,
                        "hour": trigger?.dateComponents.hour ?? -1, "minute": trigger?.dateComponents.minute ?? -1,
                        "weekday": trigger?.dateComponents.weekday ?? -1,
                        "next_delivery": trigger?.nextTriggerDate()?.ISO8601Format() ?? "none",
                        "repeats": trigger?.repeats ?? false]
            },
            "delivered": notifications.map { ["id": $0.request.identifier, "category": $0.request.content.categoryIdentifier,
                                               "date": $0.date.ISO8601Format()] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("notification-review.json"), options: .atomic)
        }
    }
}
#endif
