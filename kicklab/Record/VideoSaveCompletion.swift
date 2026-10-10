import SwiftUI
import UIKit
import UserNotifications

/// Notification taps are explicit navigation; ordinary app activation never opens Photos.
@MainActor
final class VideoSaveCompletion: NSObject, UNUserNotificationCenterDelegate {
    static let shared = VideoSaveCompletion()
    private var pendingPhotos = false
    private static let category = "video-saved"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category,
            actions: [UNNotificationAction(identifier: "open-photos", title: "Open Photos", options: .foreground)],
            intentIdentifiers: [])])
    }

    func prepare() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func saved() async {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Video saved to Photos"
        content.body = "Tap to open your video library."
        content.sound = .default
        content.categoryIdentifier = Self.category
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "video-saved-" + UUID().uuidString, content: content, trigger: nil))
    }

    func openPhotos() {
        pendingPhotos = true
        becameActive()
    }

    func becameActive() {
        guard pendingPhotos, UIApplication.shared.applicationState == .active else { return }
        pendingPhotos = false
        // Photos owns this URL scheme. No private API or asset-library permission is needed.
        UIApplication.shared.open(URL(string: "photos-redirect://")!)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == "video-saved",
              response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == "open-photos" else { return }
        await openPhotos()
    }
}

final class VideoSaveAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        VideoSaveCompletion.shared.configure()
        return true
    }
}


extension View {
    func videoSavedConfirmation(isPresented: Binding<Bool>) -> some View {
        alert("Video saved to Photos", isPresented: isPresented) {
            Button("OK") { VideoSaveCompletion.shared.openPhotos() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Your video is ready. Tap OK to open Photos.")
        }
    }
}
