#if DEBUG
import SwiftUI
import AVFoundation

/// Real-video integration harness. Uses the shipping detector, editor and exporter.
/// --effects-video /absolute/input.mp4 [--effects-export]
struct EffectsVideoReview: View {
    let url: URL
    @StateObject private var analyzer = VideoAnalyzer()
    @StateObject private var exporter = BallStyleBurnIn()
    @StateObject private var sceneModel = StadiumPreviewModel()
    @State private var overlays = ExportOverlaySettings.load()
    @State private var edit = SessionEditState(style: .fire, intensity: 0.8)
    @State private var showShare = false
    @State private var returnToApp = false
    @State private var summary: SessionSummary?
    @State private var message = "Preparing real video…"

    var body: some View {
        Group {
            if returnToApp {
                ContentView()
            } else if let summary {
                if showShare {
                    SaveShareView(summary: summary, edit: edit, sceneModel: sceneModel, overlays: $overlays, onRecordAnother: {}, onDone: { showShare = false }, onBack: { showShare = false })
                } else {
                    ReplayEffectsView(summary: summary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays, onSaveShare: { showShare = true }, onBack: { returnToApp = true })
                }
            } else {
                VStack(spacing: 20) {
                    Text(message)
                    ProgressView(value: analyzer.progress)
                    Text("\(analyzer.framesRead) frames · \(analyzer.detections) detections")
                }.padding(30)
            }
        }
        .task { await run() }
    }

    private func run() async {
        guard summary == nil, !analyzer.isRunning else { return }
        if ProcessInfo.processInfo.arguments.contains("--select-segmentation-pilot") {
            UserDefaults.standard.set("segmentation", forKey: "experimentalBallModel")
        }
        if ProcessInfo.processInfo.arguments.contains("--select-motion-model") {
            UserDefaults.standard.set("motionModel", forKey: "experimentalBallModel")
        }
        showShare = ProcessInfo.processInfo.arguments.contains("--effects-share")
        if let env = SessionDesignReview.argument("--effects-environment").flatMap(EffectEnvironment.init(rawValue:)) { edit.environment = env }
        if let style = SessionDesignReview.argument("--effects-style").flatMap(BallStyle.init(rawValue:)) { edit.style = style }
        if let skin = SessionDesignReview.argument("--effects-skin").flatMap(BallSkin.init(rawValue:)) { edit.ballSkin = skin }
        if let path = SessionDesignReview.argument("--effects-track"),
           let data = try? Data(contentsOf: SessionDesignReview.fileURL(path)),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = report["track"] as? [[String: Double]] {
            let frames = rows.compactMap { row -> RecordedFrame? in
                guard let t = row["time"], let x = row["x"], let y = row["y"], let w = row["width"], let h = row["height"], let score = row["score"] else { return nil }
                let person: PersonBox?
                if let px = row["personX"], let py = row["personY"], let pw = row["personWidth"], let ph = row["personHeight"] {
                    person = PersonBox(x: px, y: py, width: pw, height: ph)
                } else { person = nil }
                return RecordedFrame(time: t, x: x, y: y, width: w, height: h, score: score,
                    smoothedX: x, smoothedY: y, vy: 0, motion: .unknown, detected: true, person: person)
            }
            let touches = report["touches"] as? Int ?? 0
            let marks = (report["touchesMarked"] as? [[String: Double]] ?? []).enumerated().compactMap { index, row -> RecordedTouch? in
                guard let time = row["time"] else { return nil }
                return RecordedTouch(index: index, time: time, x: row["x"] ?? 0.5, y: row["y"] ?? 0.5)
            }
            summary = SessionSummary.make(touches: touches, duration: report["duration"] as? Double ?? 0,
                bestCombo: touches, personalBest: touches, videoURL: url, touchesMarked: marks, track: frames)
            await exportReview(frames: frames)
            return
        }
        analyzer.analyse(url: url)
        while analyzer.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        guard analyzer.status == "done" else { message = analyzer.status; return }
        let folder = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: SessionDesignReview.argument("--effects-folder") ?? "effects-validation").lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if ProcessInfo.processInfo.arguments.contains("--effects-mask-review") {
                let selected = [20, 98, 170, 273, 404, 576].compactMap { index -> [String: Any]? in
                    guard analyzer.recordedTrack.indices.contains(index), let m = analyzer.recordedTrack[index].ballMask else { return nil }
                    return ["frame": index, "rect": [m.rect.minX,m.rect.minY,m.rect.width,m.rect.height],
                            "width": m.width,"height": m.height,"alpha": Data(m.alpha).base64EncodedString()]
                }
                try JSONSerialization.data(withJSONObject: selected, options: [.prettyPrinted])
                    .write(to: folder.appendingPathComponent("mask-review.json"))
            }
            let rows = analyzer.recordedTrack.map { f in
                var row = ["time": f.time, "x": f.x, "y": f.y, "width": f.width, "height": f.height, "score": f.score]
                if let person = f.person {
                    row["personX"] = person.x; row["personY"] = person.y
                    row["personWidth"] = person.width; row["personHeight"] = person.height
                }
                return row
            }
            let report: [String: Any] = ["source": url.path, "frames": analyzer.framesRead,
                "detections": analyzer.detections, "rejected": analyzer.dropped, "touches": analyzer.touchCount,
                "duration": analyzer.videoDuration, "track": rows, "model": analyzer.analyzedModel, "performance": analyzer.performance,
                "follow": analyzer.followDiagnostics, "touchesMarked": analyzer.recordedTouches.map { ["time": $0.time, "x": $0.x, "y": $0.y] }]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("analysis.json"))
        } catch { message = error.localizedDescription; return }
        if let style = SessionDesignReview.argument("--effects-style").flatMap(BallStyle.init(rawValue:)) { edit.style = style }
        if let skin = SessionDesignReview.argument("--effects-skin").flatMap(BallSkin.init(rawValue:)) { edit.ballSkin = skin }
        summary = SessionSummary.make(touches: analyzer.touchCount, duration: analyzer.videoDuration,
            bestCombo: analyzer.touchCount, personalBest: analyzer.touchCount, videoURL: url,
            touchesMarked: analyzer.recordedTouches, track: analyzer.recordedTrack)
        await exportReview(frames: analyzer.recordedTrack)
    }

    private func exportReview(frames: [RecordedFrame]) async {
        guard ProcessInfo.processInfo.arguments.contains("--effects-export") else { return }
        let folderName = SessionDesignReview.argument("--effects-folder") ?? "metal-effects"
        let folder = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: folderName).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("RUNNING".utf8).write(to: folder.appendingPathComponent("status.txt"))
            let requested = SessionDesignReview.argument("--effects-only").flatMap(BallStyle.init(rawValue:))
            let variants: [BallStyle] = requested.map { [$0] } ?? BallStyle.allCases.filter { $0 != .none }
            for effect in variants {
                try Data("Rendering \(effect.title)".utf8).write(to: folder.appendingPathComponent("status.txt"))
                let start = Date()
                let baselineMemory = DetectorPerformance.memoryMB()
                let monitor = Task { @MainActor in
                    var peak = DetectorPerformance.memoryMB()
                    while !Task.isCancelled {
                        peak = max(peak, DetectorPerformance.memoryMB())
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    return peak
                }
                defer { monitor.cancel() }
                let environment = edit.environment
                let skin = edit.ballSkin
                let counter = ProcessInfo.processInfo.arguments.contains("--effects-counter")
                    ? summary.map { ExportCounterTimeline(touches: $0.touchesMarked, total: $0.touches) } : nil
                var overlays: ExportOverlaySettings?
                if counter != nil {
                    var settings = ExportOverlaySettings()
                    settings.counter.enabled = true
                    if let style = SessionDesignReview.argument("--effects-badge").flatMap(ExportBadgeStyle.init(rawValue:)) {
                        settings.counter.style = style
                    }
                    overlays = settings
                }
                if let path = SessionDesignReview.argument("--effects-overlays") {
                    overlays = try JSONDecoder().decode(ExportOverlaySettings.self, from: Data(contentsOf: SessionDesignReview.fileURL(path)))
                }
                let exportSettings = overlays
                let quality = SessionDesignReview.argument("--effects-quality") == "720" ? 720 : 1080
                let result = try await Task.detached(priority: .userInitiated) {
                    try await BallStyleBurnIn.render(source: url, track: frames, style: effect, skin: skin,
                        intensity: 0.85, environment: environment, shortEdge: quality, counter: counter, overlays: exportSettings)
                }.value
                let destination = folder.appendingPathComponent(effect.rawValue + ".mp4")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: result, to: destination)
                monitor.cancel()
                let peak = await monitor.value
                let metrics: [String: Any] = ["elapsed_s": Date().timeIntervalSince(start),
                    "baseline_app_mib": baselineMemory, "peak_sampled_app_mib": peak,
                    "after_export_app_mib": DetectorPerformance.memoryMB(), "model": analyzer.analyzedModel,
                    "scope": "Whole app; native decode/render/encode plus visible editor, 50ms samples; optimized Debug",
                    "device": UIDevice.current.model, "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                    "mask_frames": frames.filter { $0.ballMask != nil }.count]
                try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent(effect.rawValue + "-performance.json"))
            }
            try Data("COMPLETE".utf8).write(to: folder.appendingPathComponent("status.txt"))
        } catch {
            try? Data("FAILED: \(error)".utf8).write(to: folder.appendingPathComponent("status.txt"))
        }
    }
}
#endif
