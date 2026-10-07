#if DEBUG
import SwiftUI

/// Isolated visual-review entry point. Not included in Release builds.
/// Launch with --session-design summary|effects|stats|share|processing and
/// --session-video /absolute/path/to/a/review-clip.mp4. No camera/export is started.
struct SessionDesignReview: View {
    let screen: String
    @StateObject private var sceneModel = StadiumPreviewModel()
    @State private var overlays = ExportOverlaySettings.load()
    @State private var edit = SessionEditState(style: .fire, intensity: 0.7)

    static var requestedScreen: String? { argument("--session-design") }
    static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func fileURL(_ path: String) -> URL {
        if path.hasPrefix("documents:") {
            return URL.documentsDirectory.appendingPathComponent(String(path.dropFirst(10)))
        }
        return URL(fileURLWithPath:path)
    }

    static var summary: SessionSummary {
        let video = fileURL(argument("--session-video") ?? "/tmp/kicklab-design-preview.mp4")
        return SessionSummary(
            touches: 132, duration: 84, bestCombo: 28, maxHeightMeters: 0.9,
            avgHeightMeters: 0.6, personalBest: 100, videoURL: video,
            touchesMarked: (0..<132).map { RecordedTouch(index: $0, time: Double($0) * 84 / 132, x: 0.5, y: 0.60) },
            track: (0..<2520).map {
                RecordedFrame(time: Double($0) / 30, x: 0.5, y: 0.60, width: 0.08, height: 0.075,
                              score: 0.98, smoothedX: 0.5, smoothedY: 0.60, vy: 0,
                              motion: .unknown, detected: true, person: nil)
            },
            drops: 0, consistency: 0.92,
            touchTimeline: [0, 3, 8, 14, 19, 23, 31, 36, 43, 49, 53, 59, 63, 70, 77, 83, 88, 94, 102, 108, 113, 119, 125, 132]
        )
    }

    var body: some View {
        Group {
            switch screen {
            case "capture-controls": CaptureDesignReview()
            case "counter": CounterDesignReview()
            case "effects": ReplayEffectsView(summary: Self.summary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays, onSaveShare: {}, onBack: {})
            case "stats": DetailedStatsView(summary: Self.summary, onSaveShare: {}, onBack: {})
            case "share": SaveShareView(summary: Self.summary, edit: edit, sceneModel: sceneModel, overlays: $overlays, onRecordAnother: {}, onDone: {}, onBack: {})
            case "processing": ProcessingOverlay(progress: 0.65, stepIndex: 2)
            default: PostSessionFlowView(summary: Self.summary, onFinished: {}, onRecordAnother: {}, recordsPersonalBest: false)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Session summary") {
    SessionCompleteView(summary: SessionDesignReview.summary, onWatchEffects: {}, onDetailedStats: {}, onSaveShare: {})
}
#Preview("Replay editor") { SessionDesignReview(screen: "effects") }
#Preview("Detailed stats") { SessionDesignReview(screen: "stats") }
#Preview("Save and share") { SessionDesignReview(screen: "share") }
#Preview("Processing") { SessionDesignReview(screen: "processing") }
#endif
