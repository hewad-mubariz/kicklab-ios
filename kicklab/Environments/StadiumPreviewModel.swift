import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class StadiumPreviewModel: ObservableObject {
    typealias Preparation = @Sendable (URL, [StadiumBallObservation],
        @escaping @Sendable (Double) async -> Void,
        @escaping @Sendable (String) async -> Void) async throws -> PreparedStadiumPreview
    private let preparation: Preparation
    @Published private(set) var progress = 0.0
    @Published private(set) var isPreparing = false
    @Published private(set) var result: PreparedStadiumPreview?
    @Published private(set) var error: String?
    @Published private(set) var sampleLabel: String?
    @Published private(set) var preparationStage = "Opening video"
    @Published private(set) var lastProgressAt = Date()
    private var diagnosticSource: URL?
    private var diagnosticUpdatedAt = Date.distantPast
    private var preparationStartedAt = Date()
    private var stageTimeline: [[String: Any]] = []
    private static let logger = Logger(subsystem: "hewad.kicklab", category: "ScenePreparation")
    private var worker: Task<PreparedStadiumPreview, Error>?
    @Published private(set) var renderProgress = 0.0
    @Published private(set) var isRendering = false
    private var scenes: [SceneSelection: ScenePlayback] = [:]
    private var sceneTasks: [SceneSelection: Task<ScenePlayback, Error>] = [:]
    private var generation = UUID()
    private var ownedFolder: URL?

    init(preparation: @escaping Preparation = { source, observations, progress, stage in
        try await StadiumPreviewPreparer.prepare(source: source, observations: observations,
            onStage: stage, onProgress: progress)
    }) {
        self.preparation = preparation
    }

    func prepare(summary: SessionSummary) async {
        guard result == nil, !isPreparing else { return }
        let token = UUID(); generation = token
        isPreparing = true; progress = 0; error = nil
        preparationStage = "Opening video"; lastProgressAt = Date(); diagnosticSource = summary.videoURL
        preparationStartedAt = Date(); stageTimeline = []
        defer { if generation == token { isPreparing = false; worker = nil } }
        #if DEBUG
        if let path = SessionDesignReview.argument("--stadium-preview-fixture") {
            do {
                result = try loadSample(folder:SessionDesignReview.fileURL(path),source:summary.videoURL)
                progress = 1
            } catch { self.error = error.localizedDescription }
            isPreparing = false
            return
        }
        #endif
        #if DEBUG
        writeDiagnostics(status:"preparing",source:summary.videoURL)
        #endif
        let visualSummary: SessionSummary
        do { visualSummary = try await readySummary(summary) }
        catch { self.error = error.localizedDescription; isPreparing = false; return }
        let observations = visualSummary.renderTrack.filter { $0.detected && !$0.isVisualMaskRepair }.map {
            StadiumBallObservation(time:$0.time,
                bounds:CGRect(x:$0.x-$0.width/2,y:$0.y-$0.height/2,width:$0.width,height:$0.height),confidence:$0.score)
        }
        let source = summary.videoURL
        let reportProgress: @Sendable (Double) async -> Void = { [weak self] value in
            await self?.receiveProgress(value,token:token)
        }
        let operation = preparation
        let reportStage: @Sendable (String) async -> Void = { [weak self] stage in
            await self?.receiveStage(stage, token: token)
        }
        let task = VideoWorkExecution.detached {
            try await operation(source, observations, reportProgress, reportStage)
        }
        worker = task
        do {
            // Preparation belongs to the session. Dismissing/reopening the
            // environment sheet must not cancel and restart the cutout work.
            let prepared = try await task.value
            guard generation == token else { prepared.removeFiles(); return }
            guard !task.isCancelled else {
                prepared.removeFiles()
                throw CancellationError()
            }
            result = prepared; ownedFolder = prepared.folder; progress = 1
            #if DEBUG
            writeDiagnostics(status:"ready",source:source)
            #endif
        } catch {
            guard generation == token else { return }
            self.error = error is CancellationError ? "Preparation was cancelled. You can try again."
                : "\(preparationStage): \(error.localizedDescription)"
            Self.logger.error("Preparation failed at \(self.preparationStage, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #if targetEnvironment(simulator)
            if error.localizedDescription.contains("E5RT") {
                self.error = "Prepare this preview on an iPhone. This simulator can play a prepared sample, but it can’t run the cutout model."
            }
            #endif
            #if DEBUG
            writeDiagnostics(status:"failed",source:source)
            #endif
        }
        if generation == token { isPreparing = false; worker = nil }
    }

    func media(summary: SessionSummary, selection: SceneSelection?) async throws -> ScenePlayback {
        guard let selection else {
            return ScenePlayback(url: try await EffectPreviewCache.shared.preparedURL(for: summary.videoURL), track: summary.renderTrack)
        }
        let summary = try await readySummary(summary)
        if let cached = scenes[selection] { return cached }
        if let pending = sceneTasks[selection] { return try await pending.value }
        if isPreparing {
            while isPreparing { try await Task.sleep(for: .milliseconds(50)) }
        } else if result == nil { await prepare(summary: summary) }
        try Task.checkCancellation()
        guard let prepared = result else {
            throw StadiumPreviewPreparer.failure(error ?? "The scene could not be prepared.")
        }
        try SceneMovieRenderer.validate(prepared)
        // Another consumer may have requested the same scene while preparation ran.
        if let cached = scenes[selection] { return cached }
        if let pending = sceneTasks[selection] { return try await pending.value }
        let frames = summary.renderTrack.filter { !$0.isVisualMaskRepair }
        let progress: @Sendable (Double) async -> Void = { [weak self] value in
            await self?.receiveRenderProgress(value)
        }
        let task = VideoWorkExecution.detached {
            let url = try await SceneMovieRenderer.render(prepared: prepared, selection: selection, onProgress: progress)
            return ScenePlayback(url: url, track: selection.project(frames, in: prepared.recording!))
        }
        sceneTasks[selection] = task; isRendering = true; renderProgress = 0
        defer { sceneTasks[selection] = nil; isRendering = !sceneTasks.isEmpty }
        let media = try await task.value
        scenes[selection] = media
        return media
    }

    private func readySummary(_ summary: SessionSummary) async throws -> SessionSummary {
        guard summary.needsVisualPreparation else { return summary }
        let frames = try await BallVisualRefiner.refineVideo(source: summary.videoURL, frames: summary.track,
            framesUseCompositionClock: summary.framesUseCompositionClock)
        var ready = summary; ready.visualTrack = frames; ready.needsVisualPreparation = false
        return ready
    }

    private func receiveRenderProgress(_ value: Double) { renderProgress = value }

    private func receiveProgress(_ value: Double, token: UUID) {
        guard generation == token, worker?.isCancelled != true else { return }
        progress = value; lastProgressAt = Date()
        #if DEBUG
        if Date().timeIntervalSince(diagnosticUpdatedAt) >= 1, let source = diagnosticSource {
            writeDiagnostics(status: "preparing", source: source)
        }
        #endif
    }

    private func receiveStage(_ stage: String, token: UUID) {
        guard generation == token, worker?.isCancelled != true else { return }
        preparationStage = stage; lastProgressAt = Date()
        stageTimeline.append(["stage": stage, "elapsed": Date().timeIntervalSince(preparationStartedAt)])
        Self.logger.info("\(stage, privacy: .public)")
        #if DEBUG
        if let source = diagnosticSource { writeDiagnostics(status: "preparing", source: source) }
        #endif
    }

    func cancelPreparation() {
        guard let worker else { return }
        // A native Vision/Metal call may finish before it notices cancellation.
        // Keep the worker until then so retries cannot launch overlapping work.
        worker.cancel()
        preparationStage = "Stopping preparation"
    }

    deinit {
        worker?.cancel()
        for task in sceneTasks.values { task.cancel() }
        if let ownedFolder { try? FileManager.default.removeItem(at:ownedFolder) }
    }

    #if DEBUG
    private func writeDiagnostics(status: String, source: URL) {
        diagnosticUpdatedAt = Date()
        var report: [String:Any] = ["status":status,"error":error ?? "","sourceName":source.lastPathComponent,
            "stage":preparationStage,"progress":progress,"updatedAt":Date().timeIntervalSince1970,
            "elapsed":Date().timeIntervalSince(preparationStartedAt),"stages":stageTimeline]
        if let bytes = try? source.resourceValues(forKeys:[.fileSizeKey]).fileSize { report["sourceBytes"] = bytes }
        if let result {
            report["folder"] = "tmp/"+result.folder.lastPathComponent
            report["duration"] = result.duration; report["sourceDuration"] = result.sourceDuration
            report["frames"] = result.frames
            report["width"] = Int(result.size.width); report["height"] = Int(result.size.height)
        }
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:URL.documentsDirectory.appendingPathComponent("stadium-preview-status.json"),options:.atomic)
        }
    }

    private func loadSample(folder: URL, source: URL) throws -> PreparedStadiumPreview {
        guard let report = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("preview.json"))) as? [String:Any],
              report["sourceName"] as? String == source.lastPathComponent,
              report["sourceBytes"] as? Int == (try source.resourceValues(forKeys:[.fileSizeKey]).fileSize),
              let duration = report["duration"] as? Double, duration.isFinite, duration > 0,
              let sourceDuration = report["sourceDuration"] as? Double, sourceDuration.isFinite,
              let frames = report["frames"] as? Int, frames > 0,
              let width = report["width"] as? Int, width > 0,
              let height = report["height"] as? Int, height > 0,
              FileManager.default.fileExists(atPath:folder.appendingPathComponent("original.mp4").path) else {
            throw StadiumPreviewPreparer.failure("The prepared sample does not match this clip.")
        }
        let metadata=folder.appendingPathComponent("scene.json"),foreground=folder.appendingPathComponent("foreground.mp4")
        let recording=(try? Data(contentsOf:metadata)).flatMap {try? JSONDecoder().decode(StadiumSceneRecording.self,from:$0)}
        let hasForeground=recording != nil && FileManager.default.fileExists(atPath:foreground.path)
        func legacyMovie(_ name: String) -> URL? {
            let url=folder.appendingPathComponent(name+".mp4")
            return FileManager.default.fileExists(atPath:url.path) ? url:nil
        }
        let locked=legacyMovie("locked"),moving=legacyMovie("moving")
        guard hasForeground || (locked != nil && moving != nil) else {
            throw StadiumPreviewPreparer.failure("The prepared sample is missing its cutout video.")
        }
        sampleLabel = (report["preparedOn"] as? String).map { "Prepared \($0) sample" } ?? "Prepared cutout sample"
        return PreparedStadiumPreview(folder:folder,original:folder.appendingPathComponent("original.mp4"),
            locked:locked,moving:moving,
            duration:duration,sourceDuration:sourceDuration,frames:frames,size:CGSize(width:width,height:height),
            foreground:hasForeground ? foreground:nil,recording:recording)
    }
    #endif
}
