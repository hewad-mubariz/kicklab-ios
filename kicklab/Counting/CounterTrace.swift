import Foundation

/// Numeric evidence only: no camera pixels or new model inference. A trace is
/// exact only when complete, finished, and replayed by the same counter revision.
nonisolated struct CounterTrace: Codable, Sendable {
    static let currentRevision = "counter-v5"
    let revision: String
    let config: CounterConfig
    let usesHandVerifier: Bool
    var usesFootVerifier: Bool = false
    let complete: Bool
    let operations: [Operation]
    let decisions: [Decision]
    let touches: [Touch]

    struct Input: Codable, Sendable {
        let frameIndex, timestampMs: Int
        let sourceFrameIndex: Int?
        let ball: BallObservation?
        let person: PersonBox?
        let cameraOffsetY: Double
        let reliable: Bool
    }
    struct Operation: Codable, Sendable {
        let flush: Bool
        let input: Input?
    }
    struct Decision: Codable, Equatable, Sendable {
        /// Zero-based operation at which this decision became available.
        let operation: Int
        let value: CounterDecision
    }
    enum ReplayError: Error {
        case incompatibleRevision, incomplete, invalidOperation, missingHandEvidence, missingFootEvidence, differentResult
    }

    /// Reuses recorded hand verdicts, not Vision. Refuse missing evidence rather
    /// than assuming a new candidate is legal when evaluating a changed counter.
    func replay() throws -> [Touch] {
        guard revision == Self.currentRevision else { throw ReplayError.incompatibleRevision }
        guard complete, operations.last?.flush == true else { throw ReplayError.incomplete }
        let handChecks = decisions.filter { $0.value.handRejected != nil }
        var cursor = 0, missingEvidence = false, operationIndex = -1
        let verifier: ((Int) -> Bool)? = usesHandVerifier ? { frame in
            guard cursor < handChecks.count,
                  handChecks[cursor].operation == operationIndex,
                  handChecks[cursor].value.frameIndex == frame else {
                missingEvidence = true
                return false
            }
            defer { cursor += 1 }
            return handChecks[cursor].value.handRejected!
        } : nil
        let footChecks = decisions.filter { $0.value.footConfirmed != nil }
        var footCursor = 0, missingFoot = false
        let footProvider: ((Int) -> FootContactEvidence?)? = usesFootVerifier ? { frame in
            guard footCursor < footChecks.count,
                  footChecks[footCursor].operation == operationIndex,
                  footChecks[footCursor].value.frameIndex == frame else {
                missingFoot = true; return nil
            }
            defer { footCursor += 1 }
            return footChecks[footCursor].value.footEvidence
        } : nil
        let counter = StreamingCounter(config: config, rejectsHandContact: verifier, recordTrace: true,
                                       traceLimit: max(1, operations.count), footContactEvidence: footProvider)
        for (index, operation) in operations.enumerated() {
            operationIndex = index
            if operation.flush {
                guard operation.input == nil else { throw ReplayError.invalidOperation }
                counter.flush()
            } else {
                guard let input = operation.input else { throw ReplayError.invalidOperation }
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs,
                    ball: input.ball, person: input.person, cameraOffsetY: input.cameraOffsetY,
                    reliable: input.reliable, sourceFrameIndex: input.sourceFrameIndex)
            }
        }
        guard !missingEvidence, cursor == handChecks.count else { throw ReplayError.missingHandEvidence }
        guard !missingFoot, footCursor == footChecks.count else { throw ReplayError.missingFootEvidence }
        guard counter.touches == touches, counter.traceSnapshot()?.decisions == decisions else {
            throw ReplayError.differentResult
        }
        return counter.touches
    }
}

nonisolated final class CounterTraceRecorder {
    private let config: CounterConfig
    private let usesHandVerifier: Bool
    private let usesFootVerifier: Bool
    private let limit: Int
    private var complete = true
    private var operations: [CounterTrace.Operation] = []
    private var decisions: [CounterTrace.Decision] = []

    /// 18,000 operations cover about ten minutes of live inference. Longer takes
    /// keep counting normally; their bounded diagnostic is explicitly incomplete.
    init(config: CounterConfig, usesHandVerifier: Bool, usesFootVerifier: Bool = false, limit: Int = 18_000) {
        self.config = config; self.usesHandVerifier = usesHandVerifier; self.usesFootVerifier = usesFootVerifier; self.limit = max(1, limit)
    }
    func append(input: CounterTrace.Input?) {
        guard complete, operations.count < limit else { complete = false; return }
        operations.append(.init(flush: input == nil, input: input))
    }
    func append(decision: CounterDecision) {
        guard complete, !operations.isEmpty else { return }
        decisions.append(.init(operation: operations.count - 1, value: decision))
    }
    func snapshot(touches: [Touch]) -> CounterTrace {
        CounterTrace(revision: CounterTrace.currentRevision, config: config,
            usesHandVerifier: usesHandVerifier, usesFootVerifier: usesFootVerifier, complete: complete, operations: operations,
            decisions: decisions, touches: Array(touches.prefix(limit)))
    }
}

nonisolated struct CounterTraceArchive: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case capture, file }
    let sourceDigest: String
    let pipelineSignature: String
    let mode: Mode
    /// Subtract this from timestampMs/1000 for source-relative event times.
    let timeOriginSeconds: Double
    let trace: CounterTrace
}
