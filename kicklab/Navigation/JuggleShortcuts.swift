import AppIntents
import UIKit

/// "Start juggling" for Siri, Spotlight, the Shortcuts app and the Action Button.
nonisolated struct JuggleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartJugglingIntent(),
                    phrases: ["Start juggling in \(.applicationName)",
                              "Juggle with \(.applicationName)",
                              "Count my touches in \(.applicationName)"],
                    shortTitle: "Start juggling",
                    systemImageName: "soccerball")
    }
}

/// The "Start juggling" quick action on the app icon's long-press menu.
enum JuggleQuickAction {
    static let type = "com.juggledude.start-juggling"
    /// The link the Home Screen widget opens.
    static let url = URL(string: "juggledude://start-juggling")!

    static func install(on application: UIApplication) {
        application.shortcutItems = [
            UIApplicationShortcutItem(type: type,
                                      localizedTitle: String(localized: "Start juggling", bundle: AppLanguage.bundle,
                                                             locale: AppLanguage.locale),
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "soccerball"))
        ]
    }

    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == type else { return false }
        AppNotificationNavigation.shared.requestPractice()
        return true
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == Self.url.scheme, url.host == Self.url.host else { return false }
        AppNotificationNavigation.shared.requestPractice()
        return true
    }
}

/// Only here to receive the quick action while the app is already running; SwiftUI
/// still owns the window.
final class JuggleSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(JuggleQuickAction.handle(shortcutItem))
    }
}
