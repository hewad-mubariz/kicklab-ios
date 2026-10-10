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
                    ReplayEffectsView(summary: summary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays, onBack: { returnToApp = true }, onDone: { returnToApp = true })
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
        showShare = ProcessInfo.processInfo.arguments.contains("--effects-share")
        if let env = SessionDesignReview.argument("--effects-environment").flatMap(EffectEnvironment.init(rawValue:)) { edit.environment = env }
        if let style = SessionDesignReview.argument("--effects-style").flatMap(BallStyle.init(rawValue:)) { edit.style = style }
        if let skin = SessionDesignReview.argument("--effects-skin").flatMap(BallSkin.init(rawValue:)) { edit.ballSkin = skin }
        if let path = SessionDesignReview.argument("--effects-capture-preparation") {
            await capturePreparationReview(path: path)
            return
        }
        // Exact owned observations isolate rendering from model/backend differences.
        if let path = SessionDesignReview.argument("--effects-owned-track") {
            do {
                let data = try Data(contentsOf: SessionDesignReview.fileURL(path))
                let stored = try PropertyListDecoder().decode([StoredFrame].self, from: data)
                guard stored.allSatisfy(\.isValid) else { throw NSError(domain: "ParityReview", code: 3) }
                let frames = stored.map(\.frame)
                let length = try await AVURLAsset(url: url).load(.duration).seconds
                summary = SessionSummary.make(touches: 0, duration: length, bestCombo: 0, personalBest: 0,
                    videoURL: url, touchesMarked: [], track: frames)
                try PipelineParityReview.begin()
                if PipelineParityReview.enabled { try await PipelineParityReview.write(source: url, frames: frames) }
                await exportReview(frames: frames)
            } catch { message = "Owned-track review failed: \(error.localizedDescription)" }
            return
        }
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
        do { try PipelineParityReview.begin() }
        catch { message = "Parity review setup failed: \(error.localizedDescription)"; return }
        let folder = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: SessionDesignReview.argument("--effects-folder") ?? "effects-validation").lastPathComponent)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("ANALYSING".utf8).write(to: folder.appendingPathComponent("status.txt"), options: .atomic)
        analyzer.analyse(url: url)
        while analyzer.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        guard analyzer.status == "done" else {
            message = analyzer.status
            let failure = "FAILED: \(analyzer.status)\n\(analyzer.failureDiagnostic)"
            try? Data(failure.utf8).write(to: folder.appendingPathComponent("status.txt"), options: .atomic)
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try SessionAnalysisStore.frameData(analyzer.recordedTrack).write(to:folder.appendingPathComponent("counted-track.plist"))
            try SessionAnalysisStore.frameData(analyzer.visualRecoveries).write(to:folder.appendingPathComponent("visual-recoveries.plist"))
            if ProcessInfo.processInfo.arguments.contains("--effects-mask-review") {
                let selected = [20, 98, 170, 273, 404, 576].compactMap { index -> [String: Any]? in
                    guard analyzer.recordedTrack.indices.contains(index), let m = analyzer.recordedTrack[index].ballMask else { return nil }
                    return ["frame": index, "rect": [m.rect.minX,m.rect.minY,m.rect.width,m.rect.height],
                            "width": m.width,"height": m.height,"alpha": Data(m.alpha).base64EncodedString()]
                }
                try JSONSerialization.data(withJSONObject: selected, options: [.prettyPrinted])
                    .write(to: folder.appendingPathComponent("mask-review.json"))
            }
            if let trace = analyzer.counterTrace {
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(trace).write(to: folder.appendingPathComponent("counter-trace.plist"), options: .atomic)
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
        let originalSummary = SessionSummary.make(touches: analyzer.touchCount, duration: analyzer.videoDuration,
            bestCombo: analyzer.touchCount, personalBest: analyzer.touchCount, videoURL: url,
            touchesMarked: analyzer.recordedTouches, track: analyzer.recordedTrack)
        do {
            let start = ProcessInfo.processInfo.systemUptime
            let visual = ProcessInfo.processInfo.arguments.contains("--effects-no-mask-repair")
                ? analyzer.renderTrack
                : try await BallVisualRefiner.refineVideo(source: url, frames: analyzer.renderTrack,
                    framesUseCompositionClock: true)
            var finished = originalSummary
            finished.visualTrack = visual
            summary = finished
            if PipelineParityReview.enabled {
                try await Task.detached(priority:.userInitiated) {
                    try await PipelineParityReview.write(source:url,frames:visual)
                }.value
            }
            let repairs: [[String: Any]] = visual.filter(\.isVisualMaskRepair).compactMap { frame in
                guard let mask = frame.ballMask else { return nil }
                return ["time": frame.time, "x": frame.x, "y": frame.y, "width": frame.width,
                        "height": frame.height, "score": frame.score,
                        "rect": [mask.rect.minX, mask.rect.minY, mask.rect.width, mask.rect.height],
                        "maskWidth": mask.width, "maskHeight": mask.height,
                        "alpha": Data(mask.alpha).base64EncodedString()]
            }
            let report: [String: Any] = ["repairs": repairs, "original_observations": analyzer.recordedTrack.count,
                "visual_frames": visual.count, "elapsed_s": ProcessInfo.processInfo.systemUptime-start,
                "original_touches": analyzer.touchCount]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("mask-repairs.json"))
            await exportReview(frames: visual)
        } catch {
            message = "Mask review failed: \(error.localizedDescription)"
            try? Data("FAILED: \(String(reflecting: error as NSError))".utf8)
                .write(to: folder.appendingPathComponent("status.txt"), options: .atomic)
        }
    }

    /// Benchmarks the actual captured-session path, preserving its live count.
    /// No synthetic inference clock, export, or visible playback in the timings.
    private func capturePreparationReview(path: String) async {
        let folder = URL.documentsDirectory.appendingPathComponent(
            URL(fileURLWithPath: SessionDesignReview.argument("--effects-folder") ?? "preparation-review").lastPathComponent)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data("RUNNING".utf8).write(to:folder.appendingPathComponent("status.txt"))
            let capture = try PropertyListDecoder().decode(CaptureSessionTimeline.self,
                from:Data(contentsOf:SessionDesignReview.fileURL(path)))
            guard capture.sourceDigest == (try SessionAnalysisStore.sourceDigest(url)),
                  StoredFrame.validated(capture.observations) else { throw NSError(domain:"PreparationReview",code:1) }
            let marks = capture.touches.map { RecordedTouch(index:Int($0[0]),time:$0[1],x:$0[2],y:$0[3]) }
            var original = SessionSummary.make(touches:capture.count,
                duration:try await AVURLAsset(url:url).load(.duration).seconds,
                bestCombo:capture.count,personalBest:capture.count,videoURL:url,
                touchesMarked:marks,track:capture.observations.map(\.frame))
            original.needsVisualPreparation = true
            let coolingStart = ProcessInfo.processInfo.systemUptime
            if ProcessInfo.processInfo.arguments.contains("--preparation-require-nominal") {
                var nominalSince: Double?
                while true {
                    try Task.checkCancellation()
                    let now = ProcessInfo.processInfo.systemUptime
                    let thermal = ProcessInfo.processInfo.thermalState
                    if thermal == .nominal { nominalSince = nominalSince ?? now }
                    else { nominalSince = nil }
                    if let nominalSince, now - nominalSince >= 10 { break }
                    guard now - coolingStart < 300 else {
                        throw NSError(domain: "PreparationReview", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Phone did not cool to nominal within five minutes"])
                    }
                    try Data("COOLING: thermal \(thermal.rawValue)".utf8)
                        .write(to: folder.appendingPathComponent("status.txt"))
                    try await Task.sleep(for: .seconds(2))
                }
                try Data("RUNNING".utf8).write(to: folder.appendingPathComponent("status.txt"))
            }
            let start = ProcessInfo.processInfo.systemUptime
            let startingThermal = ProcessInfo.processInfo.thermalState.rawValue
            let preparation = SessionEffectsPreparation()
            let ready = try await preparation.prepare(original)
            let masksReady = ProcessInfo.processInfo.systemUptime
            let motion = ProcessInfo.processInfo.arguments.contains("--analysis-ignore-cache")
                ? try await BallSurfaceTimeline.analyzeForReview(source:url,track:BallEffectTrack(frames:ready.renderTrack))
                : try await BallSurfaceTimeline.prepare(source:url,track:BallEffectTrack(frames:ready.renderTrack))
            let finished = ProcessInfo.processInfo.systemUptime
            let poses = motion.entries.map { [$0.time,Double($0.orientation.vector.x),Double($0.orientation.vector.y),
                Double($0.orientation.vector.z),Double($0.orientation.vector.w),$0.accepted ? 1.0 : 0.0,$0.visible ? 1.0 : 0.0] }
            let metrics: [String:Any] = ["visual_preparation_s":masksReady-start,"spin_s":finished-masksReady,
                "total_s":finished-start,"source_duration":original.duration,"live_count":original.touches,
                "prepared_count":ready.touches,"markers_preserved":marks == ready.touchesMarked,
                "visual_frames":ready.renderTrack.count,"spin_frames":motion.entries.count,
                "spin_accepted":motion.acceptedCount,"thermal":ProcessInfo.processInfo.thermalState.rawValue,
                "thermal_start":startingThermal,"visual_batch_requested":BallDetector.visualBatchSize(visualOnly:true) == 2,
                "cooling_s":start-coolingStart,
                "mask_bytes":ready.renderTrack.reduce(0) { $0+($1.ballMask?.alpha.count ?? 0) }]
            try JSONSerialization.data(withJSONObject:metrics,options:[.sortedKeys,.prettyPrinted])
                .write(to:folder.appendingPathComponent("preparation.json"))
            try SessionAnalysisStore.frameData(ready.renderTrack).write(to:folder.appendingPathComponent("visual.plist"))
            try JSONSerialization.data(withJSONObject:poses).write(to:folder.appendingPathComponent("poses.json"))
            summary = ready
            if ProcessInfo.processInfo.arguments.contains("--effects-export") { await exportReview(frames:ready.renderTrack) }
            else { try Data("COMPLETE".utf8).write(to:folder.appendingPathComponent("status.txt")) }
        } catch {
            message = "Preparation review failed: \(error.localizedDescription)"
            try? Data("FAILED: \(error)".utf8).write(to:folder.appendingPathComponent("status.txt"))
        }
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
                let touchTimes = summary?.touchesMarked.map(\.time) ?? []
                let exportSettings = overlays
                let quality = SessionDesignReview.argument("--effects-quality") == "720" ? 720 : 1080
                let result = try await Task.detached(priority: .userInitiated) {
                    try await BallStyleBurnIn.render(source: url, track: frames, style: effect, skin: skin,
                        intensity: 0.85, environment: environment, shortEdge: quality, counter: counter, overlays: exportSettings, touchTimes: touchTimes)
                }.value
                let destination = folder.appendingPathComponent(effect.rawValue + ".mp4")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: result, to: destination)
                monitor.cancel()
                let peak = await monitor.value
                var metrics: [String: Any] = ["elapsed_s": Date().timeIntervalSince(start),
                    "baseline_app_mib": baselineMemory, "peak_sampled_app_mib": peak,
                    "after_export_app_mib": DetectorPerformance.memoryMB(), "model": analyzer.analyzedModel,
                    "scope": "Whole app; native decode/render/encode plus visible editor, 50ms samples; optimized Debug",
                    "device": UIDevice.current.model, "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                    "mask_frames": frames.filter { $0.ballMask != nil }.count]
                if skin != .original {
                    let motion = try await BallSurfaceTimeline.prepare(source: url, track: BallEffectTrack(frames: frames))
                    metrics["surface_motion_frames"] = motion.entries.count
                    metrics["surface_motion_accepted"] = motion.acceptedCount
                    metrics["uses_source_rotation"] = motion.usesSourceRotation
                    metrics["surface_motion_prepare_s"] = motion.elapsed
                    let poses = motion.entries.map { entry in
                        ["time": entry.time, "accepted": entry.accepted,
                         "quaternion_xyzw": [entry.orientation.vector.x, entry.orientation.vector.y,
                                             entry.orientation.vector.z, entry.orientation.vector.w]] as [String: Any]
                    }
                    try JSONSerialization.data(withJSONObject: poses)
                        .write(to: folder.appendingPathComponent("surface-motion.json"))
                }
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
