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

    func prepare(_ summary: SessionSummary) async throws -> SessionSummary {
        if source != summary.videoURL { cancel(); prepared = nil; source = summary.videoURL }
        if let prepared, prepared.videoURL == summary.videoURL { return prepared }
        if let worker { return try await worker.value }
        guard summary.needsVisualPreparation else { prepared = summary; return summary }
        let token = UUID(); generation = token
        isPreparing = true; progress = 0; error = nil
        let task = VideoWorkExecution.detached { [weak self] in
            let frames = try await BallVisualRefiner.refineVideo(source: summary.videoURL,
                frames: summary.renderTrack, framesUseCompositionClock: summary.framesUseCompositionClock) { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.progress = value
                }
            }
            try Task.checkCancellation()
            var result = summary; result.visualTrack = frames; result.needsVisualPreparation = false
            return result
        }
        worker = task
        do {
            let result = try await task.value
            guard generation == token else { throw CancellationError() }
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
