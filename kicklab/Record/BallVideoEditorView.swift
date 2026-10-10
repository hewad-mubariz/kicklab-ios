import SwiftUI

struct BallVideoEditorSession: Identifiable {
    let id = UUID()
    let summary: SessionSummary
    let distance: BallDistanceTimeline?
}

/// Uses the juggling editor's ball and effects tools without touch statistics,
/// leaderboards, or changes to the player's saved juggling overlay preferences.
struct BallVideoEditorView: View {
    let session: BallVideoEditorSession
    let onFinished: () -> Void
    @StateObject private var preparation = SessionEffectsPreparation()
    @StateObject private var scene = StadiumPreviewModel()
    @State private var edit = SessionEditState(style: .fire, intensity: 0.85)
    @State private var overlays: ExportOverlaySettings = {
        var value = ExportOverlaySettings(); value.counter.enabled = false; return value
    }()

    var body: some View {
        ReplayEffectsView(summary: preparation.prepared ?? session.summary,
            edit: $edit, stadiumPreview: scene, overlays: $overlays,
            onBack: finish, onRecordAnother: finish, onDone: finish,
            preparation: preparation, showsTouchTools: false, distanceTimeline: session.distance)
    }

    private func finish() { preparation.cancel(); onFinished() }
}
