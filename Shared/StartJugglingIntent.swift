import AppIntents

/// Opens Juggle Dude straight into the juggling camera. Built into both the app (Siri,
/// Spotlight, Shortcuts, the Action Button) and the widget extension (the Control
/// Center and Lock Screen button), so the system can run it from either. It always
/// runs in the app, which waits until nothing else is on screen before opening the
/// camera, as it does for a practice reminder.
nonisolated struct StartJugglingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start juggling"
    static let description = IntentDescription("Opens the camera to count your touches.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !JUGGLE_WIDGET_EXTENSION
        AppNotificationNavigation.shared.requestPractice()
        #endif
        return .result()
    }
}
