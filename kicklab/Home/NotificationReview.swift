#if DEBUG
import SwiftUI
import UserNotifications

/// Exercises the real settings and OS scheduler on a dedicated preview install.
struct NotificationReview: View {
    @State private var pending = "Loading"
    @State private var delivered = "Loading"
    var body: some View {
        NavigationStack {
            VStack {
                NotificationSettingsView()
                Text(pending).accessibilityIdentifier("notification-review-pending")
                Text(delivered).accessibilityIdentifier("notification-review-delivered")
                Button("Refresh notification check") { Task { await inspect() } }
                    .accessibilityIdentifier("notification-review-refresh")
            }.task { await inspect() }
        }
    }

    private func inspect() async {
        await PracticeNotifications.shared.refresh()
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let notifications = await center.deliveredNotifications()
        pending = "\(requests.filter { $0.identifier == PracticeNotifications.reminderIdentifier }.count) daily reminders"
        delivered = "\(notifications.filter { $0.request.content.categoryIdentifier == "video-saved" }.count) export alerts"
        let value: [String: Any] = [
            "authorization": await center.notificationSettings().authorizationStatus.rawValue,
            "pending": requests.map { request -> [String: Any] in
                let trigger = request.trigger as? UNCalendarNotificationTrigger
                return ["id": request.identifier, "title": request.content.title,
                        "hour": trigger?.dateComponents.hour ?? -1, "minute": trigger?.dateComponents.minute ?? -1,
                        "repeats": trigger?.repeats ?? false]
            },
            "delivered": notifications.map { ["id": $0.request.identifier, "category": $0.request.content.categoryIdentifier] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("notification-review.json"), options: .atomic)
        }
    }
}
#endif
