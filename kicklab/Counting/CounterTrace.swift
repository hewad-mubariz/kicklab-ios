import Foundation

/// Numeric evidence only: no camera pixels or new model inference. A trace is
/// exact only when complete, finished, and replayed by the same counter revision.
nonisolated struct CounterTrace: Codable, Sendable {
    static let currentRevision = "counter-v9"
    let revision: String
    let config: CounterConfig
    let usesHandVerifier: Bool
    var usesFootVerifier: Bool = false
    /// Optional so existing traces without the experiment remain decodable.
    var usesBodyVerifier: Bool? = nil
    var usesGroundVerifier: Bool? = nil
    var usesHandlingVerifier: Bool? = nil
    let complete: Bool
    let operations: [Operation]
    let decisions: [Decision]
    let touches: [Touch]
    /// Optional, debug-only annotations. Never used as counting evidence.
    var diagnostics: [TouchDebugEvent]? = nil

    struct Input: Codable, Sendable {
        let frameIndex, timestampMs: Int
        let sourceFrameIndex: Int?
        let ball: BallObservation?
        let person: PersonBox?
        let cameraOffsetY: Double
        let reliable: Bool
        var player: ActivePlayerSelection? = nil
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
        case incompatibleRevision, incomplete, invalidOperation, missingHandEvidence, missingFootEvidence, missingBodyEvidence, missingGroundEvidence, missingHandlingEvidence, differentResult
    }

    /// Reuses recorded hand verdicts, not Vision. Refuse missing evidence rather
    /// than assuming a new candidate is legal when evaluating a changed counter.
    func replay() throws -> [Touch] {
        guard [Self.currentRevision, "counter-v5", "counter-v6", "counter-v7", "counter-v8"].contains(revision) else { throw ReplayError.incompatibleRevision }
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
        let bodyChecks = decisions.filter { $0.value.bodyContactAllowed != nil }
        var bodyCursor = 0, missingBody = false
        let bodyVerifier: ((Int) -> Bool)? = usesBodyVerifier == true ? { frame in
            guard bodyCursor < bodyChecks.count,
                  bodyChecks[bodyCursor].operation == operationIndex,
                  bodyChecks[bodyCursor].value.frameIndex == frame else {
                missingBody = true; return false
            }
            defer { bodyCursor += 1 }
            return bodyChecks[bodyCursor].value.bodyContactAllowed!
        } : nil
        let groundChecks = decisions.filter { $0.value.plantedFeetConfirmed != nil }
        var groundCursor = 0, missingGround = false
        let groundProvider: ((Int) -> GroundContactEvidence?)? = usesGroundVerifier == true ? { frame in
            guard groundCursor < groundChecks.count,
                  groundChecks[groundCursor].operation == operationIndex,
                  groundChecks[groundCursor].value.frameIndex == frame else {
                missingGround = true; return nil
            }
            defer { groundCursor += 1 }
            return groundChecks[groundCursor].value.groundEvidence
        } : nil
        let handlingChecks = decisions.filter { $0.value.handlingChecked == true }
        var handlingCursor = 0, missingHandling = false
        let handlingProvider: ((Int) -> BallHandlingEvidence?)? = usesHandlingVerifier == true ? { frame in
            guard handlingCursor < handlingChecks.count,
                  handlingChecks[handlingCursor].operation == operationIndex,
                  handlingChecks[handlingCursor].value.frameIndex == frame else {
                missingHandling = true; return nil
            }
            defer { handlingCursor += 1 }
            return handlingChecks[handlingCursor].value.handlingEvidence
        } : nil
        let counter = StreamingCounter(config: config, rejectsHandContact: verifier, recordTrace: true,
                                       traceLimit: max(1, operations.count), footContactEvidence: footProvider,
                                       allowsBodyContact: bodyVerifier,
                                       groundPolicy: revision == "counter-v5" ? .legacyCenter :
                                        (revision == "counter-v6" ? .observedBoundary :
                                            (revision == "counter-v7" ? .supportedBoundary :
                                                (revision == "counter-v8" ? .plantedFeet : .corroboratedFeet))),
                                       groundContactEvidence: groundProvider, handlingEvidence: handlingProvider)
        for (index, operation) in operations.enumerated() {
            operationIndex = index
            if operation.flush {
                guard operation.input == nil else { throw ReplayError.invalidOperation }
                counter.flush()
            } else {
                guard let input = operation.input else { throw ReplayError.invalidOperation }
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs,
                    ball: input.ball, person: input.person, cameraOffsetY: input.cameraOffsetY,
                    reliable: input.reliable, sourceFrameIndex: input.sourceFrameIndex, player: input.player)
            }
        }
        guard !missingEvidence, cursor == handChecks.count else { throw ReplayError.missingHandEvidence }
        guard !missingFoot, footCursor == footChecks.count else { throw ReplayError.missingFootEvidence }
        guard !missingBody, bodyCursor == bodyChecks.count else { throw ReplayError.missingBodyEvidence }
        guard !missingGround, groundCursor == groundChecks.count else { throw ReplayError.missingGroundEvidence }
        guard !missingHandling, handlingCursor == handlingChecks.count else { throw ReplayError.missingHandlingEvidence }
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
    private let usesBodyVerifier: Bool
    private let usesGroundVerifier: Bool
    private let usesHandlingVerifier: Bool
    private let limit: Int
    private let revision: String
    private var complete = true
    private var operations: [CounterTrace.Operation] = []
    private var decisions: [CounterTrace.Decision] = []
    private var diagnostics: [TouchDebugEvent]? = nil

    /// 18,000 operations cover about ten minutes of live inference. Longer takes
    /// keep counting normally; their bounded diagnostic is explicitly incomplete.
    init(config: CounterConfig, usesHandVerifier: Bool, usesFootVerifier: Bool = false,
         usesBodyVerifier: Bool = false, usesGroundVerifier: Bool = false,
         usesHandlingVerifier: Bool = false, limit: Int = 18_000, revision: String = CounterTrace.currentRevision) {
        self.config = config; self.usesHandVerifier = usesHandVerifier; self.usesFootVerifier = usesFootVerifier; self.limit = max(1, limit)
        self.usesBodyVerifier = usesBodyVerifier
        self.usesGroundVerifier = usesGroundVerifier
        self.usesHandlingVerifier = usesHandlingVerifier
        self.revision = revision
    }
    func append(input: CounterTrace.Input?) {
        guard complete, operations.count < limit else { complete = false; return }
        operations.append(.init(flush: input == nil, input: input))
    }
    func append(decision: CounterDecision) {
        guard complete, !operations.isEmpty else { return }
        decisions.append(.init(operation: operations.count - 1, value: decision))
    }
    func append(diagnostic: TouchDebugEvent) {
        guard complete, !operations.isEmpty, (diagnostics?.count ?? 0) < limit else { return }
        if diagnostics == nil { diagnostics = [] }
        diagnostics?.append(diagnostic)
    }
    func snapshot(touches: [Touch]) -> CounterTrace {
        CounterTrace(revision: revision, config: config,
            usesHandVerifier: usesHandVerifier, usesFootVerifier: usesFootVerifier,
            usesBodyVerifier: usesBodyVerifier ? true : nil, usesGroundVerifier: usesGroundVerifier ? true : nil,
            usesHandlingVerifier: usesHandlingVerifier ? true : nil, complete: complete, operations: operations,
            decisions: decisions, touches: Array(touches.prefix(limit)), diagnostics: diagnostics)
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
