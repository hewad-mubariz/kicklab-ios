import Foundation

/// Legacy diagnostic schema for saved MediaPipe field tests. Current runs emit
/// the zero/disabled default; this type does not load or execute a model.
nonisolated struct ShoePosePerformance: Codable, Sendable {
    var enabled = false
    var calls = 0
    var errors = 0
    var framesWithPose = 0
    var totalMS = 0.0
    var loadMS = 0.0
    var inferenceMS = 0.0
    var maxInferenceMS = 0.0
    var proofRequests = 0
    var proofs = 0
    /// Process footprint around initialization, not an isolated model allocation.
    var appMemoryBeforeLoadMiB: Double?
    var appMemoryAfterLoadMiB: Double?

    var meanInferenceMS: Double { calls > 0 ? inferenceMS / Double(calls) : 0 }
    var observedLoadMemoryDeltaMiB: Double? {
        guard let before = appMemoryBeforeLoadMiB, let after = appMemoryAfterLoadMiB else { return nil }
        return after - before
    }
}
