#if DEBUG
import AVFoundation
import BackgroundTasks
import Combine
import SwiftUI

/// Physical-device verification: launch with a staged video, then press Home.
struct BackgroundVideoReview: View {
    @StateObject private var model = BackgroundVideoReviewModel()
    @State private var showSaved = false
    var body: some View {
        VStack(spacing: 16) {
            Text("Background video check").font(.title2)
            Text(model.status).accessibilityIdentifier("background-video-status")
            if SessionDesignReview.argument("--background-video-review") == "photos" {
                Button("Saved video") { showSaved = true }.accessibilityIdentifier("review-saved-video")
            }
            Text("\(model.backgroundUpdates) background updates").accessibilityIdentifier("background-video-updates")
        }.task { await model.run() }
            .videoSavedConfirmation(isPresented: $showSaved)
    }
}

@MainActor
private final class BackgroundVideoReviewModel: ObservableObject {
    @Published var status = "Starting"
    @Published var backgroundUpdates = 0
    private let analyzer = VideoAnalyzer()
    private var previousProgress = 0.0

    func run() async {
        let mode = SessionDesignReview.argument("--background-video-review") ?? "import"
        if mode == "photos" { status = "Ready"; return }
        let source = SessionDesignReview.fileURL(SessionDesignReview.argument("--background-video-source") ?? "documents:background-input.mov")
        do {
            if mode == "import" {
                analyzer.analyse(url: source)
                while analyzer.isRunning {
                    record(progress: analyzer.progress, phase: "Importing")
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard analyzer.status == "done" else { throw NSError(domain: "Review", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: analyzer.status]) }
            } else {
                try await VideoBackgroundWork.shared.run(title: "Exporting test video") {
                    // Time for Home/Lock after a real background lease is granted.
                    for tick in 0..<20 {
                        try await VideoWorkExecution.checkpoint()
                        VideoWorkExecution.lease?.progress(Double(tick) / 100, subtitle: "Preparing test export")
                        await self.record(progress: Double(tick) / 100, phase: "Preparing export")
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    let task = VideoWorkExecution.detached {
                        if mode == "shot" || mode == "shot-cancel" {
                            let frames = (0...1200).map { i -> RecordedFrame in
                                let t = Double(i) / 60, f = t.truncatingRemainder(dividingBy: 1)
                                return RecordedFrame(time: t, x: 0.3 + f * 0.3, y: 0.8 - f * 0.5,
                                    width: 0.06, height: 0.04, score: 0.9, smoothedX: 0.3 + f * 0.3,
                                    smoothedY: 0.8 - f * 0.5, vy: 0, motion: .unknown, detected: true, person: nil)
                            }
                            return try await ShotEffectExporter.render(source: source, track: BallEffectTrack(frames: frames),
                                style: .fireTrail, camera: ShotCameraSettings(style: .split)) { value in
                                    VideoWorkExecution.lease?.progress(0.2 + value * 0.8, subtitle: "Exporting shot")
                                    if mode == "shot-cancel" && value >= 0.3 { VideoWorkExecution.lease?.expire() }
                                    Task { await self.record(progress: value, phase: "Exporting") }
                                }
                        }
                        var settings = ExportOverlaySettings()
                        settings.counter.enabled = false; settings.graph.enabled = true
                        return try await BallStyleBurnIn.render(source: source, track: [], style: .none,
                            intensity: 0, shortEdge: 720, overlays: settings, motionTimeline: MotionStyleSample.timeline) { value in
                                VideoWorkExecution.lease?.progress(0.2 + value * 0.8, subtitle: "Exporting test video")
                                await self.record(progress: value, phase: "Exporting")
                            }
                    }
                    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    let destination = URL.documentsDirectory.appendingPathComponent("background-export." + result.pathExtension)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: result, to: destination)
                }
            }
            record(progress: 1, phase: "Done")
        } catch { record(progress: 0, phase: "Failed: " + error.localizedDescription) }
    }

    private func record(progress: Double, phase: String) {
        let background = UIApplication.shared.applicationState == .background
        if background && progress > previousProgress && (phase == "Exporting" || phase == "Importing") { backgroundUpdates += 1 }
        previousProgress = progress
        status = phase
        let value: [String: Any] = ["phase": phase, "progress": progress, "background": background,
            "backgroundUpdates": backgroundUpdates, "gpuSupported": BGTaskScheduler.supportedResources.contains(.gpu),
            "analysisFrames": analyzer.framesRead, "touches": analyzer.touchCount,
            "time": Date().timeIntervalSince1970, "performance": analyzer.performance]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("background-video-review.json"), options: .atomic)
        }
    }
}
#endif
