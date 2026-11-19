import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center, Lock Screen and Action Button control that opens the camera.
struct StartJugglingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.juggledude.start-juggling-control") {
            ControlWidgetButton(action: StartJugglingIntent()) {
                Label("Start juggling", systemImage: "soccerball")
            }
        }
        .displayName("Start juggling")
        .description("Opens the camera to count your touches.")
    }
}
