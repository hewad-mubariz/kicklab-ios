#if DEBUG
import SwiftUI
import UserNotifications

/// Exercises the real settings and OS scheduler on a dedicated preview install.
struct NotificationReview: View {
    @State private var pending = "Loading"
    @State private var delivered = "Loading"
    @State private var dailyDelivered = "Loading"
    var body: some View {
        NavigationStack {
            VStack {
                NotificationSettingsView()
                Text(pending).accessibilityIdentifier("notification-review-pending")
                Text(delivered).accessibilityIdentifier("notification-review-delivered")
                Text(dailyDelivered).accessibilityIdentifier("notification-review-daily-delivered")
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
        let value: [String: Any] = [
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
