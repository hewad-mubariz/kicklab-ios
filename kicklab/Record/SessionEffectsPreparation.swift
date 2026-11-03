import Combine
import Foundation

/// Owned by the session flow so preview and Save & Share observe one task.
@MainActor
final class SessionEffectsPreparation: ObservableObject {
    @Published private(set) var prepared: SessionSummary?
    @Published private(set) var isPreparing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    private var worker: Task<SessionSummary, Error>?
    private var generation = UUID()
    private var source: URL?

    /// `everyFrame` asks a fast import's replacement ball for a silhouette on every source frame, for
    /// a download at the original frame rate; otherwise it gets the faster download's 60 fps.
    func prepare(_ summary: SessionSummary, for edit: SessionEditState, everyFrame: Bool = false) async throws -> SessionSummary {
        guard edit.requiresVisualTrack else { return summary }
        return try await prepare(summary, dense: edit.usesBallMaterial, everyFrame: everyFrame)
    }

    func prepare(_ summary: SessionSummary) async throws -> SessionSummary {
        try await prepare(summary, dense: true)
    }

    private func covers(_ result: SessionSummary, dense: Bool, everyFrame: Bool) -> Bool {
        guard dense else { return true }
        return !result.visualTrackIsPositionsOnly
            && (!everyFrame || !result.framesUseCompositionClock || BallVisualRefiner.analysedEveryFrame(result.renderTrack))
    }

    private func prepare(_ summary: SessionSummary, dense: Bool, everyFrame: Bool = false) async throws -> SessionSummary {
        if source != summary.videoURL { cancel(); prepared = nil; source = summary.videoURL }
        if let prepared, prepared.videoURL == summary.videoURL,
           covers(prepared, dense: dense, everyFrame: everyFrame) { return prepared }
        if let worker {
            let token = generation
            let result = try await worker.value
            try Task.checkCancellation()
            guard generation == token, source == summary.videoURL else { throw CancellationError() }
            if covers(result, dense: dense, everyFrame: everyFrame) { return result }
            // Let the initiating caller publish completion before upgrading.
            while self.worker != nil && generation == token { await Task.yield() }
            guard generation == token else { throw CancellationError() }
            return try await prepare(summary, dense: true, everyFrame: everyFrame)
        }
        let needsMoreFrames = dense && everyFrame && summary.framesUseCompositionClock
            && !BallVisualRefiner.analysedEveryFrame(summary.renderTrack)
        guard summary.needsVisualPreparation || (dense && summary.visualTrackIsPositionsOnly) || needsMoreFrames else {
            prepared = summary; return summary
        }
        let token = UUID(); generation = token
        isPreparing = true; progress = 0; error = nil
        let hasOnlyPositions = summary.visualTrackIsPositionsOnly && summary.renderTrack.allSatisfy { $0.ballMask == nil }
        let task = VideoWorkExecution.detached { [weak self] in
            let progress: @Sendable (Double) -> Void = { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.progress = value
                }
            }
            var selective = false
            if !dense && !summary.framesUseCompositionClock {
                selective = try await SelectiveEffectTrack.canReuse(source: summary.videoURL, frames: summary.track)
            }
            let frames: [RecordedFrame]
            if dense && hasOnlyPositions {
                // Older history entries retained only positions. Never pass those
                // stripped observations off as completed replacement masks.
                let fastClip = try await VideoProcessingInfo.load(summary.videoURL).fps >= 100
                let fresh = try await VideoAnalyzer.replayTrack(source: summary.videoURL,
                    maxFrameRate: !everyFrame && fastClip ? ExportChoice.fasterFrameRate : nil) { progress($0 * 0.9) }
                frames = try await BallVisualRefiner.refineVideo(source: summary.videoURL, frames: fresh,
                    framesUseCompositionClock: true, denseMasks: true, everyFrame: everyFrame) { progress(0.9 + $0 * 0.1) }
            } else if selective {
                frames = try await SelectiveEffectTrack.refine(source: summary.videoURL, frames: summary.track, onProgress: progress)
            } else {
                frames = try await BallVisualRefiner.refineVideo(source: summary.videoURL,
                    frames: summary.visualTrackIsPositionsOnly ? summary.track : summary.renderTrack,
                    framesUseCompositionClock: summary.framesUseCompositionClock, denseMasks: dense,
                    everyFrame: everyFrame, onProgress: progress)
            }
            try Task.checkCancellation()
            var result = summary; result.visualTrack = frames; result.needsVisualPreparation = false
            // An import counted at 30 fps keeps positions only until a replacement ball asks for more.
            result.visualTrackIsPositionsOnly = selective
                || (summary.framesUseCompositionClock && !dense && !BallVisualRefiner.analysedEveryFrame(frames))
            return result
        }
        worker = task
        do {
            let result = try await task.value
            guard generation == token else { throw CancellationError() }
            #if DEBUG && TOUCH_COUNTING_DEBUG
            RFEffectsRoutingAudit.prepared(original: summary, result: result)
            #endif
            prepared = result; progress = 1; isPreparing = false; worker = nil
            return result
        } catch {
            if generation == token {
                isPreparing = false; worker = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            throw error
        }
    }

    func cancel() {
        generation = UUID(); worker?.cancel(); worker = nil; isPreparing = false
    }
}
