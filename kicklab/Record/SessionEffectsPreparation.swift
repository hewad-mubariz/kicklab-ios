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

    func prepare(_ summary: SessionSummary, for edit: SessionEditState) async throws -> SessionSummary {
        guard edit.requiresVisualTrack else { return summary }
        return try await prepare(summary, dense: edit.ballSkin != .original)
    }

    func prepare(_ summary: SessionSummary) async throws -> SessionSummary {
        try await prepare(summary, dense: true)
    }

    private func prepare(_ summary: SessionSummary, dense: Bool) async throws -> SessionSummary {
        if source != summary.videoURL { cancel(); prepared = nil; source = summary.videoURL }
        if let prepared, prepared.videoURL == summary.videoURL,
           !dense || !prepared.visualTrackIsPositionsOnly { return prepared }
        if let worker {
            let token = generation
            let result = try await worker.value
            try Task.checkCancellation()
            guard generation == token, source == summary.videoURL else { throw CancellationError() }
            if !dense || !result.visualTrackIsPositionsOnly { return result }
            // Let the initiating caller publish completion before upgrading.
            while self.worker != nil && generation == token { await Task.yield() }
            guard generation == token else { throw CancellationError() }
            return try await prepare(summary, dense: true)
        }
        guard summary.needsVisualPreparation || (dense && summary.visualTrackIsPositionsOnly) else {
            prepared = summary; return summary
        }
        let token = UUID(); generation = token
        isPreparing = true; progress = 0; error = nil
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
            if selective {
                frames = try await SelectiveEffectTrack.refine(source: summary.videoURL, frames: summary.track, onProgress: progress)
            } else {
                frames = try await BallVisualRefiner.refineVideo(source: summary.videoURL,
                    frames: summary.visualTrackIsPositionsOnly ? summary.track : summary.renderTrack,
                    framesUseCompositionClock: summary.framesUseCompositionClock, onProgress: progress)
            }
            try Task.checkCancellation()
            var result = summary; result.visualTrack = frames; result.needsVisualPreparation = false
            result.visualTrackIsPositionsOnly = selective
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
