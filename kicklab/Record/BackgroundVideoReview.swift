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
                if showSaved {
                    ReplaySavedToast(thumbnail: nil, detail: "1080p · 0:16")
                }
            }
            Text("\(model.backgroundUpdates) background updates").accessibilityIdentifier("background-video-updates")
        }.task { await model.run() }
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
            if mode == "artwork" {
                // Match a prepared editor session: source-motion analysis finishes before Save.
                record(progress:0,phase:"Preparing ball")
                _ = try await BallSurfaceTimeline.prepare(source:source,track:BallEffectTrack(frames:Self.artworkFrames()))
            }
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
                        if mode == "artwork" {
                            // A staged 320x480, 20-second fixture with a white ball at (160,240), r=48.
                            // Exercise the real exporter after Home, including CPU-only background time.
                            return try await BallStyleBurnIn.render(source:source,track:Self.artworkFrames(),style:.none,skin:.arctic,
                                intensity:0,shortEdge:320,preserveFrameTimes:true) { value in
                                    VideoWorkExecution.lease?.progress(0.2+value*0.8,subtitle:"Exporting artwork")
                                    await self.record(progress:value,phase:"Exporting")
                                }
                        }
                        if mode == "shot" || mode == "shot-cancel" {
                            let frames = (0...1200).map { i -> RecordedFrame in
                                let t = Double(i) / 60, f = t.truncatingRemainder(dividingBy: 1)
                                return RecordedFrame(time: t, x: 0.3 + f * 0.3, y: 0.8 - f * 0.5,
                                    width: 0.06, height: 0.04, score: 0.9, smoothedX: 0.3 + f * 0.3,
                                    smoothedY: 0.8 - f * 0.5, vy: 0, motion: .unknown, detected: true, person: nil)
                            }
                            return try await ShotEffectExporter.render(source: source, track: BallEffectTrack(frames: frames),
                                style: .fireTrail, camera: ShotCameraTrack(clips: [ShotCameraClip(move: .split, start: 0, end: 20)])) { value in
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

    nonisolated private static func artworkFrames() -> [RecordedFrame] {
        let alpha = (0..<10000).map { i -> UInt8 in
            hypot(Double(i%100)+0.5-50,Double(i/100)+0.5-50) < 48 ? 255 : 0
        }
        let mask = BallMask(rect:CGRect(x:110.0/320,y:190.0/480,width:100.0/320,height:100.0/480),width:100,height:100,alpha:alpha)
        return (0..<600).map { i in
            RecordedFrame(time:Double(i)/30,x:0.5,y:0.5,width:96.0/320,height:96.0/480,score:0.99,
                smoothedX:0.5,smoothedY:0.5,vy:0,motion:.unknown,detected:true,person:nil,ballMask:mask,usesBallMasks:true)
        }
    }

    private func record(progress: Double, phase: String) {
        let background = UIApplication.shared.applicationState == .background
        if background && progress > previousProgress && (phase == "Exporting" || phase == "Importing") { backgroundUpdates += 1 }
        previousProgress = progress
        status = phase
        let gpuSupported: Bool
        if #available(iOS 26.0, *) { gpuSupported = BGTaskScheduler.supportedResources.contains(.gpu) }
        else { gpuSupported = false }
        let value: [String: Any] = ["phase": phase, "progress": progress, "background": background,
            "backgroundUpdates": backgroundUpdates, "gpuSupported": gpuSupported,
            "analysisFrames": analyzer.framesRead, "touches": analyzer.touchCount,
            "artworkGPUAllowed": BallSkinMetalRenderer.isAllowed,
            "backgroundLeaseAllowed": VideoWorkExecution.lease?.canContinue ?? false,
            "time": Date().timeIntervalSince1970, "performance": analyzer.performance]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("background-video-review.json"), options: .atomic)
        }
    }
}
#endif
