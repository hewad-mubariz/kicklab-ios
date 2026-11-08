import SwiftUI
import UIKit

struct NotificationSettingsView: View {
    @ObservedObject private var notifications = PracticeNotifications.shared
    @ObservedObject private var remote = RemotePracticeNotifications.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section {
                Toggle("Practice reminders", isOn: Binding(
                    get: { notifications.practiceEnabled },
                    set: { value in Task { await notifications.setPracticeEnabled(value); await remote.refresh() } }))
                    .accessibilityIdentifier("notifications-practice")
                if notifications.practiceEnabled {
                    DatePicker("Reminder time", selection: Binding(get: { reminderTime }, set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        Task {
                            await notifications.setTime(hour: parts.hour ?? 18, minute: parts.minute ?? 0)
                            await remote.refresh()
                        }
                    }), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("notifications-time")
                }
            } footer: {
                Text("Three reminders a week: Monday, Wednesday and Sunday, at your chosen local time.")
            }
            Section {
                Toggle("Leaderboard updates", isOn: Binding(
                    get: { notifications.leaderboardEnabled },
                    set: { value in Task { await notifications.setLeaderboardEnabled(value); await remote.refresh() } }))
                    .accessibilityIdentifier("notifications-leaderboard")
            } footer: {
                Text("Get notified when your leaderboard position changes. Requires a signed-in leaderboard profile.")
            }
            if let error = remote.errorMessage {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry push connection") { Task { await remote.refresh() } }
                }
            }
            Section {
                Toggle("Export finished", isOn: Binding(
                    get: { notifications.exportsEnabled },
                    set: { value in Task { await notifications.setExportsEnabled(value) } }))
                    .accessibilityIdentifier("notifications-exports")
            } footer: {
                Text("Get notified when a replay finishes saving to Photos while you’re outside Juggle Dude.")
            }
            if notifications.authorization == .denied {
                Section {
                    Label("Notifications are off in iPhone Settings", systemImage: "bell.slash")
                        .accessibilityIdentifier("notifications-denied")
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.accessibilityIdentifier("notifications-system-settings")
                } footer: {
                    Text("Your choices are saved. Allow notifications in Settings to receive them.")
                }
            }
            if let error = notifications.errorMessage {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await notifications.refresh() } }
                }
            }
        }
        .disabled(notifications.isUpdating)
        .scrollContentBackground(.hidden)
        .background(TrainingHomeStyle.background(scheme))
        .navigationTitle(String(localized: "Notifications", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refresh(); await remote.refresh() }
    }

    private var reminderTime: Date {
        Calendar.current.date(bySettingHour: notifications.minuteOfDay / 60,
                              minute: notifications.minuteOfDay % 60, second: 0, of: Date()) ?? Date()
    }
}
