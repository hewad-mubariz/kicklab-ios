#if DEBUG
import SwiftUI
import UserNotifications

/// Exercises the real settings and OS scheduler on a dedicated preview install.
struct NotificationReview: View {
    /// A local fixture exercises the same category/delegate/navigation as the
    /// real APNs message, without bypassing the server's daily delivery cap.
    static func scheduleTapCheckIfRequested() async {
        guard Bundle.main.bundleIdentifier == "com.juggledude.release120.preview",
              ProcessInfo.processInfo.arguments.contains("--notification-tap-review") else { return }
        let center = UNUserNotificationCenter.current()
        guard PracticeNotifications.allows(await center.notificationSettings().authorizationStatus) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Juggle Dude notification tap check"
        content.body = "Test alert: tap to open juggling setup."
        content.categoryIdentifier = RemotePracticeNotifications.category
        try? await center.add(UNNotificationRequest(identifier: "juggledude.notification-tap-check",
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 8, repeats: false)))
    }
    @State private var pending = "Loading"
    @State private var delivered = "Loading"
    @State private var dailyDelivered = "Loading"
    @State private var pushStatus = "Loading"
    var body: some View {
        NavigationStack {
            VStack {
                NotificationSettingsView()
                Text(pending).accessibilityIdentifier("notification-review-pending")
                Text(delivered).accessibilityIdentifier("notification-review-delivered")
                Text(dailyDelivered).accessibilityIdentifier("notification-review-daily-delivered")
                Text(pushStatus).font(.caption).accessibilityIdentifier("notification-review-push")
                if Bundle.main.bundleIdentifier == "com.juggledude.release120.preview" {
                    Button("Schedule reminder about one minute from now") {
                        Task {
                            let time = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(90))
                            guard let hour = time.hour, let minute = time.minute else { return }
                            await PracticeNotifications.shared.setTime(hour: hour, minute: minute)
                            await inspect()
                        }
                    }.accessibilityIdentifier("notification-review-soon")
                    Button("Restore default reminder time") {
                        Task { await PracticeNotifications.shared.setTime(hour: 18, minute: 0); await inspect() }
                    }.accessibilityIdentifier("notification-review-default-time")
                    Button("Clear delivered test reminder") {
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [PracticeNotifications.reminderIdentifier])
                        Task { await inspect(refresh: false) }
                    }.accessibilityIdentifier("notification-review-clear-daily")
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
        pending = "\(requests.filter { $0.identifier == PracticeNotifications.reminderIdentifier }.count) daily reminders"
        delivered = "\(notifications.filter { $0.request.content.categoryIdentifier == "video-saved" }.count) export alerts"
        dailyDelivered = "\(notifications.filter { $0.request.content.categoryIdentifier == PracticeNotifications.reminderCategory }.count) daily alerts"
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
