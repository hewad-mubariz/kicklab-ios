#if DEBUG
import SwiftUI

/// Isolated visual-review entry point. Not included in Release builds.
/// Launch with --session-design summary|effects|stats|share|processing and
/// --session-video /absolute/path/to/a/review-clip.mp4. No camera/export is started.
struct SessionDesignReview: View {
    let screen: String
    @State private var closedPaywall = false
    @State private var closedLeaderboard = false
    @StateObject private var sceneModel = StadiumPreviewModel()
    @State private var overlays = ExportOverlaySettings.load()
    @State private var edit = SessionEditState(style: .fire, intensity: 0.7)

    static var requestedScreen: String? { argument("--session-design") }
    nonisolated static func argument(_ flag: String) -> String? {
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
        if requestedScreen == "motion-replay" {
            return SessionSummary(
                touches: MotionStyleSample.touches.count, duration: MotionStyleSample.duration,
                bestCombo: 7, maxHeightMeters: nil, avgHeightMeters: nil, personalBest: 7, videoURL: video,
                touchesMarked: MotionStyleSample.touches.enumerated().map {
                    RecordedTouch(index: $0.offset, time: $0.element, x: 0.5, y: 0.86)
                },
                track: MotionStyleSample.points.map {
                    RecordedFrame(time: $0.time, x: $0.x ?? 0.5, y: $0.y ?? 0.86, width: 0.08, height: 0.075,
                                  score: 0.98, smoothedX: $0.x ?? 0.5, smoothedY: $0.y ?? 0.86, vy: 0,
                                  motion: .unknown, detected: true, person: nil)
                }, drops: 0, consistency: 0.92, touchTimeline: [1, 2, 3, 4, 5, 6, 7])
        }
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
            case "ball-video":
                // The Power Shot editor, as an imported video opens it.
                ShotEffectsReplayView(video: Self.fileURL(Self.argument("--session-video") ?? "/tmp/kicklab-design-preview.mp4"),
                                      onClose: {})
            case "motion-styles": MotionStylesDesignReview()
            case "capture-controls": CaptureDesignReview()
            case "capture-preparing": CaptureDesignReview(initialState: .preparing)
            case "counter": CounterDesignReview()
            case "effects": ReplayEffectsView(summary: Self.summary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays, onBack: {})
            case "stats": DetailedStatsView(summary: Self.summary, onSaveShare: {}, onBack: {})
            case "share": SaveShareView(summary: Self.summary, edit: edit, sceneModel: sceneModel, overlays: $overlays, onRecordAnother: {}, onDone: {}, onBack: {})
            case "processing": ProcessingOverlay(progress: 0.65, stepIndex: 2)
            case "processing-cooling": ProcessingOverlay(progress: 0.65, stepIndex: 2,
                statusMessage: "Cooling down. Your video will continue automatically.", onCancel: {}, isPaused: true)
            case "processing-demo": ProcessingDemo()
            case "export-concept": ExportConceptView(concept: Self.argument("--concept") ?? "A",
                                                     state: Self.argument("--export-state") ?? "idle")
            case "signin-demo": SignInDemo()
            case "shot-effects":
                ShotEffectsReplayView(video: Self.fileURL(Self.argument("--shot-video") ?? ""),
                                      style: Self.argument("--shot-style").flatMap(ShotTrailStyle.init(rawValue:)) ?? .limeRibbon,
                                      trackCache: Self.argument("--shot-track-cache").map { URL(fileURLWithPath: $0) },
                                      holdAt: Self.argument("--shot-hold").flatMap(Double.init),
                                      graph: Self.argument("--shot-graph").flatMap(ShotGraphStyle.init(rawValue:)), onClose: {})
            case "shot-camera-fixture": ShotCameraReviewFixture()
            case "powershot-effects": PowerShotEffectConceptView(effect: Self.argument("--concept") ?? "tracer",
                                                                 scenePath: Self.argument("--shot-scene"))
            case "shot-graphs": ShotGraphReview(style: Self.argument("--shot-graph").flatMap(ShotGraphStyle.init(rawValue:)) ?? .comet,
                                                trackPath: Self.argument("--shot-track-cache"),
                                                trail: Self.argument("--shot-style").flatMap(ShotTrailStyle.init(rawValue:)) ?? .limeRibbon)
            case "powershot-data": PowerShotDataConceptView(screen: Self.argument("--concept") ?? "flight",
                                                            scenePath: Self.argument("--shot-scene"))
            case "paywall":
                if closedPaywall { ContentView() }
                else { ProPaywallView { closedPaywall = true } }
            case "leaderboard":
                if closedLeaderboard { ContentView() }
                else { LeaderboardView { closedLeaderboard = true } }
            case "leaderboard-concept": LeaderboardConceptView(concept: Self.argument("--concept") ?? "A",
                                                               state: Self.argument("--lb-state") ?? "main")
            case "signin-concept": SignInConceptView(concept: Self.argument("--concept") ?? "A",
                                                     state: Self.argument("--signin-state") ?? "welcome")
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
/// Runs the processing screen from start to finish over about 16 seconds.
private struct ProcessingDemo: View {
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let t = context.date.timeIntervalSince(started)
            let progress = min(1, t / 16)
            ProcessingOverlay(progress: progress, stepIndex: t >= 16 ? 4 : progress < 0.2 ? 0 : progress < 0.6 ? 1 : progress < 0.9 ? 2 : 3)
        }
    }
}
#endif
