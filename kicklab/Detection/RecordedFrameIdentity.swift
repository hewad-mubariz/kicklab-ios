import CoreMedia
import Foundation

/// Exact identity of a frame actually accepted by the writer. Live counter
/// timestamps remain untouched; visual reuse can use this rational source time.
nonisolated struct RecordedFrameIdentity: Codable, Equatable, Sendable {
    let index: Int
    let value: Int64
    let timescale: Int32
    let width: Int
    let height: Int
    let coordinates: String

    init(index: Int, time: CMTime, width: Int, height: Int, coordinates: String) {
        self.index = index; value = time.value; timescale = time.timescale
        self.width = width; self.height = height; self.coordinates = coordinates
    }
    var isValid: Bool { index >= 0 && value >= 0 && timescale > 0
        && (1...65536).contains(width) && (1...65536).contains(height) && !coordinates.isEmpty }
    var seconds: Double { Double(value) / Double(timescale) }
}

/// A compact ledger records both analyzed misses and saved frames which were
/// never analyzed. That distinction is required before selective repair is safe.
nonisolated struct CaptureSessionTimeline: Codable, Sendable {
    let version: Int
    let sourceDigest: String
    let frames: [RecordedFrameIdentity]
    let analyzed: [RecordedFrameIdentity]
    let observations: [StoredFrame]
    let touches: [[Double]]
    let count: Int
    /// Absent on legacy captures. A missing observation alone never proves that
    /// inference succeeded or that a saved frame is safe to skip.
    let evidence: CaptureAnalysisEvidence?

    static func persist(source: URL, frames: [RecordedFrameIdentity], analyzed: [RecordedFrameIdentity],
                        observations: [RecordedFrame], touches: [RecordedTouch], count: Int,
                        counterTrace: CounterTrace? = nil, timeOriginSeconds: Double = 0,
                        evidence: CaptureAnalysisEvidence? = nil) async {
        do {
            let digest = try SessionAnalysisStore.sourceDigest(source)
            // Counter evidence survives even when the visual-mask cache is too
            // large. It contains no pixels and does not change saved live events.
            if let counterTrace {
                await SessionAnalysisStore.shared.saveCounterTrace(CounterTraceArchive(sourceDigest: digest,
                    pipelineSignature: SessionAnalysisStore.pipelineSignature(), mode: .capture,
                    timeOriginSeconds: timeOriginSeconds, trace: counterTrace))
            }
            guard SessionAnalysisStore.canStore(observations) else { return }
            let value = CaptureSessionTimeline(version:evidence == nil ? 1 : 2,sourceDigest:digest,frames:frames,analyzed:analyzed,
                observations:observations.map(StoredFrame.init),
                touches:touches.map { [Double($0.index),$0.time,$0.x,$0.y] },count:count,evidence:evidence)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(value)
            await SessionAnalysisStore.shared.saveCapture(data,key:digest)
        } catch { NSLog("KickLab capture timeline: %@",error.localizedDescription) }
    }
}

/// Evidence for a future selective-preparation policy, not permission to skip
/// inference. Pixel-clock correspondence, detector-state replay and visual/spin
/// quality still need independent validation. Default preparation is unchanged.
nonisolated struct CaptureAnalysisEvidence: Codable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case observed, empty, failed, rejected, notReusable

        static func classify(succeeded: Bool, hasBall: Bool, hasMask: Bool,
                             maskModel: Bool, rejected: Bool, direct: Bool) -> Self {
            guard succeeded else { return .failed }
            guard !rejected else { return .rejected }
            guard maskModel, direct else { return .notReusable }
            if hasBall { return hasMask ? .observed : .notReusable }
            return hasMask ? .notReusable : .empty
        }
    }
    struct Evaluation: Codable, Sendable {
        let identity: RecordedFrameIdentity
        let outcome: Outcome
    }
    let version: Int
    let pipelineSignature: String
    let evaluations: [Evaluation]

    /// Only returns complete, internally consistent evidence for the exact
    /// source and capture pipeline. Legacy or changed builds fail closed.
    func validatedOutcomes(in capture: CaptureSessionTimeline, sourceDigest: String,
                           pipelineSignature expected: String) -> [Int: Outcome]? {
        guard capture.version == 2, version == 1, !expected.isEmpty,
              pipelineSignature == expected, !sourceDigest.isEmpty,
              capture.sourceDigest == sourceDigest,
              evaluations.count == capture.analyzed.count,
              StoredFrame.validated(capture.observations) else { return nil }
        var saved: [Int: RecordedFrameIdentity] = [:]
        var lastTime = -Double.infinity
        for (index, identity) in capture.frames.enumerated() {
            guard identity.isValid, identity.index == index,
                  identity.coordinates == "capture-buffer; normalized upright detector coordinates",
                  identity.width == capture.frames.first?.width,
                  identity.height == capture.frames.first?.height,
                  identity.seconds > lastTime else { return nil }
            saved[index] = identity; lastTime = identity.seconds
        }
        var results: [Int: Outcome] = [:]
        var previous = -1
        for (identity, evaluation) in zip(capture.analyzed, evaluations) {
            guard identity.isValid, identity.index > previous,
                  saved[identity.index] == identity, evaluation.identity == identity else { return nil }
            previous = identity.index; results[identity.index] = evaluation.outcome
        }
        var observations = Set<Int>()
        for frame in capture.observations {
            // Writer-dropped observations cannot silently be retimed onto a
            // neighbouring saved frame; conservative fallback for this archive.
            guard let identity = frame.identity, saved[identity.index] == identity,
                  observations.insert(identity.index).inserted,
                  let outcome = results[identity.index],
                  outcome == .observed || outcome == .notReusable else { return nil }
            if outcome == .observed {
                guard frame.detected, frame.usesMasks, !frame.repair, frame.maskRect != nil else { return nil }
            }
        }
        guard results.allSatisfy({ $0.value != .observed || observations.contains($0.key) }) else { return nil }
        return results
    }
}
