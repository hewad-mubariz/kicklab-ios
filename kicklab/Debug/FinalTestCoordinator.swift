#if DEBUG
import AVFoundation
import Combine
import Darwin
import UIKit

/// Guided real-app validation. Sampling and journals observe the existing pipeline;
/// only an explicitly armed test requests a stop at its target video duration.
@MainActor
final class FinalTestCoordinator: ObservableObject {
    static let shared = FinalTestCoordinator()
    static let root = URL.documentsDirectory.appendingPathComponent("FinalValidation", isDirectory: true)
    @Published private(set) var armedSeconds: Int?
    @Published private(set) var report: FinalTestReport?
    @Published private(set) var history: [FinalTestReport] = []
    @Published private(set) var message = "Choose a duration, then use the normal Record button."
    @Published private(set) var analysisRunning = false
    @Published private(set) var analysisProgress = 0.0
    private var files: FinalTestFiles?
    private weak var camera: CameraSession?
    private var sampler: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var analyzer: VideoAnalyzer?
    private var previousIdleTimer: Bool?
    private var previousBatteryMonitoring: Bool?
    private var replayPosition = 0.0
    private var replayPlaying = false
    private var replayVisible = false
    private var observers: [NSObjectProtocol] = []

    var folder: URL? { report.map { Self.root.appendingPathComponent($0.id.uuidString) } }
    var retainedVideo: URL? {
        guard let name = report?.retainedVideoName else { return nil }
        return folder?.appendingPathComponent(name)
    }
    var busy: Bool { report?.stages.values.contains { $0.status == "running" } == true }
    var canAnalyze: Bool { retainedVideo != nil && !busy && !analysisRunning }

    private init() {
        reloadHistory()
        for var interrupted in history where interrupted.stages.values.contains(where: { $0.status == "running" }) {
            interrupted.recoverInterruptedStages()
            if let store = try? FinalTestFiles(directory: Self.root.appendingPathComponent(interrupted.id.uuidString)) {
                store.save(interrupted, as: "report.json")
            }
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification,
                     ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let event = note.name.rawValue
                Task { @MainActor [weak self] in self?.event(event) }
            })
        }
    }

    func arm(_ seconds: Int) {
        guard !busy, !analysisRunning, FinalTestReport.durations.contains(seconds) else { return }
        armedSeconds = seconds
        message = "Armed for \(Self.label(seconds)). Press Record in the camera."
    }
    func disarm() { armedSeconds = nil; message = "Duration test disarmed." }

    /// Called only after normal camera preconditions have succeeded.
    func beginCapture(_ camera: CameraSession) -> FinalTestFiles? {
        guard let seconds = armedSeconds, !busy else { return nil }
        armedSeconds = nil
        let now = Date()
        let id = UUID()
        let build = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))"
        report = FinalTestReport(id: id, targetSeconds: seconds, started: now, updated: now,
            build: build, device: "\(UIDevice.current.model) (\(Self.hardwareModel))", os: UIDevice.current.systemVersion,
            model: RFSmallModel(rawValue: BallDetector.configuredResourceName)?.displayName ?? BallDetector.configuredResourceName,
            pipeline: SessionAnalysisStore.pipelineSignature())
        guard openFiles(id) else { return nil }
        files?.ensureJournal("live-contacts.jsonl")
        self.camera = camera
        replayVisible = false
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        startSampling()
        stage("recording", status: "running", detail: "Normal live capture; auto-stop uses recorded video time.")
        message = "Recording test \(Self.label(seconds)); stops automatically."
        return files
    }

    func captureStopping(_ camera: CameraSession) {
        guard self.camera === camera, report?.stages["recording"]?.status == "running" else { return }
        stage("recording", status: "running", detail: "Finishing writer and live analysis.")
    }

    func captureFinished(_ camera: CameraSession, traceComplete: Bool, touches: [RecordedTouch]) {
        guard self.camera === camera, let id = report?.id, let files else { return }
        restoreIdleTimer()
        let stats = camera.capturePerformance
        report?.liveTouches = camera.touchCount
        let target = Double(report?.targetSeconds ?? 0)
        let status = camera.recordingError != nil ? "failed" : (stats.duration + 0.1 >= target ? "completed" : "short")
        stage("recording", status: status, detail: camera.recordingError ?? (status == "short" ? "Stopped before target duration." : "Target duration reached."),
              metrics: ["video_seconds": stats.duration, "live_touches": Double(camera.touchCount),
                        "analyzed_frames": Double(stats.analysedFrames), "numeric_trace_complete": traceComplete ? 1 : 0])
        files.save(stats, as: "capture.json")
        files.save(touches.map { [$0.time, Double($0.index), $0.x, $0.y] }, as: "live-touches.json")
        if let log = camera.performance.logURL {
            Task.detached(priority: .utility) {
                do { try FileManager.default.copyItem(at: log, to: files.directory.appendingPathComponent("detector.csv")) }
                catch { await self.storageFailed(error.localizedDescription, id: id) }
            }
        }
        self.camera = nil
        guard let source = camera.recordingURL else {
            stage("video", status: "failed", detail: "No recorded video returned."); return
        }
        report?.originalVideoName = source.lastPathComponent
        stage("video", status: "running", detail: "Retaining original video and checking duration / first and last frame.")
        Task {
            do {
                let name = "source.\(source.pathExtension.isEmpty ? "mov" : source.pathExtension)"
                let saved = files.directory.appendingPathComponent(name)
                let digest = try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(at: source, to: saved)
                    return try SessionAnalysisStore.sourceDigest(saved)
                }.value
                let info = try await Self.inspectVideo(saved)
                guard report?.id == id else { return }
                report?.retainedVideoName = name; report?.sourceSHA256 = digest
                let valid = abs((info["duration_s"] ?? 0) - stats.duration) < 1
                stage("video", status: valid ? "completed" : "failed", detail: "Original retained. First/last frame decoded; full decoding is checked by fresh analysis.", metrics: info)
                message = "Video retained. Review replay, run fresh analysis, then Download the export."
            } catch { stage("video", status: "failed", detail: error.localizedDescription) }
        }
    }

    func matches(_ source: URL) -> Bool {
        report?.originalVideoName == source.lastPathComponent || retainedVideo == source
    }
    func liveContacts(_ source: URL) async -> [TouchDebugEvent]? {
        guard matches(source), let files else { return nil }
        await files.flush()
        let url = files.directory.appendingPathComponent("live-contacts.jsonl")
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(TouchDebugEvent.self, from: Data($0)) }
        }.value
    }

    func replayOpened(_ source: URL, duration: Double) {
        guard matches(source) else { return }
        replayVisible = true; startSampling()
        stage("replay", status: "opened", detail: "Editor opened. Playback, counter and timer still require visual review.", metrics: ["duration_s": duration])
    }
    func replaySample(_ source: URL, position: Double, playing: Bool) {
        guard matches(source) else { return }
        replayPosition = position; replayPlaying = playing
    }
    func replayClosed(_ source: URL) {
        guard matches(source) else { return }
        replayVisible = false; replayPlaying = false
        event("replay_closed")
    }
    func replayFailed(_ source: URL, message: String) {
        guard matches(source) else { return }
        stage("replay", status: "failed", detail: message)
    }

    func exportStarted(_ source: URL, settings: ExportOverlaySettings) {
        guard matches(source) else { return }
        startSampling()
        stage("export", status: "running", detail: "Normal Download flow, including save to Photos.",
              metrics: ["counter_enabled": settings.counter.enabled ? 1 : 0, "timer_enabled": settings.showTimer ? 1 : 0])
    }
    func exportProgress(_ source: URL, progress: Double, saving: Bool) {
        guard matches(source), report?.stages["export"]?.status == "running" else { return }
        report?.stages["export"]?.metrics["progress"] = progress
        report?.stages["export"]?.detail = saving ? "Saving to Photos" : "Rendering"
    }
    func exportFinished(_ source: URL, output: URL?, error: String?) async {
        guard matches(source), let id = report?.id, let files else { return }
        if let error { stage("export", status: "failed", detail: error); return }
        guard let output else { stage("export", status: "failed", detail: "Export returned no file."); return }
        do {
            let name = "export-\(UUID().uuidString).\(output.pathExtension)"
            let destination = files.directory.appendingPathComponent(name)
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: output, to: destination)
            }.value
            let metrics = try await Self.inspectVideo(destination)
            guard report?.id == id else { return }
            report?.retainedExportName = name
            let expected = report?.stages["video"]?.metrics["duration_s"] ?? 0
            let valid = expected > 0 && abs((metrics["duration_s"] ?? 0) - expected) < 1
            stage("export", status: valid ? "completed" : "failed", detail: "Saved to Photos and retained in report folder. Inspect the exported counter/timer visually.", metrics: metrics)
        } catch { stage("export", status: "failed", detail: error.localizedDescription) }
    }

    func analyzeSavedVideo() {
        guard canAnalyze, let source = retainedVideo, let files, let id = report?.id else { return }
        analysisRunning = true; analysisProgress = 0
        let analyzer = VideoAnalyzer(); self.analyzer = analyzer
        let attempt = "analysis-\(UUID().uuidString)"
        let analysisFiles: FinalTestFiles
        do {
            analysisFiles = try FinalTestFiles(directory: files.directory.appendingPathComponent(attempt)) { [weak self] error in
                Task { @MainActor [weak self] in self?.storageFailed(error, id: id) }
            }
        } catch { analysisRunning = false; storageFailed(error.localizedDescription, id: id); return }
        report?.analysisDirectory = attempt
        report?.analysisBuild = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))"
        report?.analysisPipeline = SessionAnalysisStore.pipelineSignature()
        analysisFiles.ensureJournal("analysis-contacts.jsonl")
        analyzer.finalTestFiles = analysisFiles
        stage("analysis", status: "running", detail: "Fresh saved-pixel analysis; cache bypassed. Live score stays unchanged.")
        startSampling()
        analysisTask = Task {
            analyzer.analyse(url: source)
            await analyzer.waitUntilFinished()
            await analysisFiles.flush()
            guard report?.id == id else { return }
            report?.analyzedTouches = analyzer.touchCount
            var metrics = analyzer.performance
            metrics["cache_bypassed"] = 1
            metrics["frames_read"] = Double(analyzer.framesRead)
            metrics["detections"] = Double(analyzer.detections)
            metrics["touches"] = Double(analyzer.touchCount)
            metrics["live_count_difference"] = Double(analyzer.touchCount - (report?.liveTouches ?? 0))
            metrics["numeric_trace_complete"] = analyzer.counterTrace?.complete == true ? 1 : 0
            analysisFiles.save(analyzer.recordedTouches.map { [$0.time, Double($0.index), $0.x, $0.y] }, as: "analysis-touches.json")
            if let trace = analyzer.counterTrace {
                analysisFiles.save(trace, as: "analysis-counter.json")
            }
            stage("analysis", status: analyzer.status == "done" ? "completed" : "failed",
                  detail: analyzer.status == "done" ? "Full video decoded and counted. Count differences require visual review, not automatic correction." : analyzer.status, metrics: metrics)
            analysisRunning = false; analysisProgress = analyzer.progress
            self.analyzer = nil; analysisTask = nil
            message = "Fresh analysis finished. Check accepted/rejected timestamps against the retained video."
        }
    }
    func cancelAnalysis() { analyzer?.cancel() }

    func review(_ key: String, value: String) {
        guard FinalTestReport.reviewNames.contains(key), ["pending", "passed", "issues"].contains(value) else { return }
        report?.reviews[key] = value; persist()
    }
    func saveNotes(_ notes: String, expected: String) {
        report?.notes = notes
        report?.expectedTouches = Int(expected).flatMap { $0 >= 0 ? $0 : nil }
        persist()
    }
    func select(_ run: FinalTestReport) {
        guard !busy, !analysisRunning else { return }
        report = run; report?.recoverInterruptedStages()
        replayVisible = false; camera = nil
        if openFiles(run.id) { persist() }
    }
    func reloadHistory() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        history = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("report.json")) else { return nil }
            return try? decoder.decode(FinalTestReport.self, from: data)
        }.sorted { $0.started > $1.started }
    }

    private func openFiles(_ id: UUID) -> Bool {
        do {
            files = try FinalTestFiles(directory: Self.root.appendingPathComponent(id.uuidString)) { [weak self] error in
                Task { @MainActor [weak self] in self?.storageFailed(error, id: id) }
            }
            return true
        } catch { report?.storageError = error.localizedDescription; message = error.localizedDescription; return false }
    }
    private func storageFailed(_ error: String, id: UUID) {
        guard report?.id == id else { return }
        report?.storageError = error; message = "Report storage failed: \(error)"
        // Do not retry a failing disk write in a loop. The error stays visible.
    }
    private func stage(_ name: String, status: String, detail: String, metrics: [String: Double] = [:]) {
        guard report != nil else { return }
        var value = report?.stages[name] ?? .init()
        if status == "running", value.status != "running" { value.started = Date(); value.finished = nil }
        if value.started == nil { value.started = Date() }
        if status != "running" { value.finished = Date() }
        value.status = status; value.detail = detail
        value.metrics.merge(metrics) { _, new in new }
        if let start = value.started, let finish = value.finished { value.metrics["wall_seconds"] = finish.timeIntervalSince(start) }
        report?.stages[name] = value
        files?.append(StageEvent(time: Date(), stage: name, value: value), to: "stages.jsonl")
        persist()
    }
    private func persist() {
        report?.updated = Date()
        if let report, report.storageError == nil { files?.save(report, as: "report.json") }
    }
    private func startSampling() {
        guard sampler == nil else { return }
        previousBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        sampler = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 4 == 0 { self.sample(); self.persist() }
                if let camera = self.camera, let target = self.report?.targetSeconds,
                   camera.isRecording, max(camera.recordingElapsed, camera.capturePerformance.duration) >= Double(target) { camera.stopRecording() }
                if !self.busy && !self.replayVisible && !self.analysisRunning {
                    self.sampler = nil
                    if let previous = self.previousBatteryMonitoring { UIDevice.current.isBatteryMonitoringEnabled = previous }
                    self.previousBatteryMonitoring = nil
                    return
                }
                tick += 1
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
    private func sample() {
        guard let report, let files else { return }
        let thermal = Self.thermal
        let memory = DetectorPerformance.memoryMB()
        self.report?.peakMemoryMiB = max(report.peakMemoryMiB, memory)
        let order = ["nominal", "fair", "serious", "critical", "unknown"]
        if (order.firstIndex(of: thermal) ?? 4) > (order.firstIndex(of: report.worstThermal) ?? 4) { self.report?.worstThermal = thermal }
        let performance = camera?.performance
        var stats = camera?.capturePerformance
        if let camera { stats?.analysedFrames = camera.processedFrames }
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: Self.root.path)[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        analysisProgress = analyzer?.progress ?? analysisProgress
        let sample = Sample(time: Date(), uptime: ProcessInfo.processInfo.systemUptime,
            stages: report.stages.filter { $0.value.status == "running" }.map(\.key).sorted(),
            thermal: thermal, memoryMiB: memory, freeDiskMiB: free / 1_048_576,
            batteryLevel: UIDevice.current.batteryLevel, batteryState: UIDevice.current.batteryState.rawValue,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            foreground: UIApplication.shared.applicationState == .active,
            capture: stats, analysisFPS: performance?.processedFPS, inferenceMS: performance?.inferenceMS,
            detectorP95MS: performance?.p95MS, livePerformance: performance?.live, liveP95MS: performance?.liveP95MS,
            analysisTargetFPS: performance?.analysisTargetFPS, analysisIdle: performance?.analysisIdle,
            retainedMaskBytes: performance?.retainedMaskBytes,
            liveTouches: camera?.touchCount,
            analysisProgress: analyzer?.progress, analysisFrames: analyzer?.framesRead,
            replayPosition: replayVisible ? replayPosition : nil, replayPlaying: replayVisible ? replayPlaying : nil)
        if report.storageError == nil { files.append(sample, to: "samples.jsonl") }
    }
    private func event(_ name: String) {
        guard report != nil else { return }
        files?.append(["time": ISO8601DateFormatter().string(from: Date()), "event": name, "thermal": Self.thermal], to: "events.jsonl")
        sample(); persist()
    }
    private func restoreIdleTimer() {
        if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        previousIdleTimer = nil
    }
    private static var hardwareModel: String {
        var length = 0
        guard sysctlbyname("hw.machine", nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.machine", &bytes, &length, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
    static func label(_ seconds: Int) -> String { seconds < 60 ? "\(seconds)s" : "\(seconds / 60) min" }

    private nonisolated static func inspectVideo(_ url: URL) async throws -> [String: Double] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "FinalValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Video is empty or unreadable."])
        }
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let generator = AVAssetImageGenerator(asset: asset); generator.maximumSize = CGSize(width: 320, height: 320)
        _ = try await generator.image(at: .zero)
        _ = try await generator.image(at: CMTime(seconds: max(0, duration - 0.2), preferredTimescale: 600))
        let bytes = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["duration_s": duration, "width": size.width, "height": size.height, "nominal_fps": Double(fps), "file_bytes": Double(bytes)]
    }

    private nonisolated struct StageEvent: Codable, Sendable { let time: Date; let stage: String; let value: FinalTestReport.Stage }
    private nonisolated struct Sample: Codable, Sendable {
        let time: Date; let uptime: Double; let stages: [String]
        let thermal: String; let memoryMiB: Double; let freeDiskMiB: Double
        let batteryLevel: Float; let batteryState: Int; let lowPower: Bool; let foreground: Bool
        let capture: CaptureCadenceSnapshot?; let analysisFPS: Double?; let inferenceMS: Double?; let detectorP95MS: Double?
        let livePerformance: LivePerformanceSummary?; let liveP95MS: Double?
        let analysisTargetFPS: Double?; let analysisIdle: Bool?; let retainedMaskBytes: Int?
        let liveTouches: Int?; let analysisProgress: Double?; let analysisFrames: Int?
        let replayPosition: Double?; let replayPlaying: Bool?
    }
}
#endif
