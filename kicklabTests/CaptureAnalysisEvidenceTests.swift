import CoreMedia
import XCTest
@testable import kicklab

final class CaptureAnalysisEvidenceTests: XCTestCase {
    private typealias Outcome = CaptureAnalysisEvidence.Outcome
    private func identity(_ index: Int, width: Int = 720) -> RecordedFrameIdentity {
        .init(index: index, time: CMTime(value: Int64(index), timescale: 60),
              width: width, height: 1280, coordinates: "capture-buffer; normalized upright detector coordinates")
    }
    private func fixture(version: Int = 2, signature: String = "pipeline",
                         outcomes: [Outcome] = [.empty, .observed, .failed, .rejected, .notReusable],
                         analyzed: [RecordedFrameIdentity]? = nil,
                         evaluations: [CaptureAnalysisEvidence.Evaluation]? = nil,
                         observationIdentity: RecordedFrameIdentity? = nil,
                         includesObservation: Bool = true) -> CaptureSessionTimeline {
        let ids = (0..<5).map { identity($0) }
        let evidence = CaptureAnalysisEvidence(version: 1, pipelineSignature: signature,
            evaluations: evaluations ?? zip(ids, outcomes).map { .init(identity: $0.0, outcome: $0.1) })
        let mask = BallMask(rect: .init(x: 0.4, y: 0.4, width: 0.1, height: 0.1),
                            width: 2, height: 2, alpha: [0, 64, 128, 255])
        var frame = RecordedFrame(time: 1.0/60, x: 0.45, y: 0.45, width: 0.1, height: 0.1,
            score: 0.95, smoothedX: 0.44, smoothedY: 0.43, vy: 0.01, motion: .rising,
            detected: true, person: nil, ballMask: mask, usesBallMasks: true)
        frame.identity = observationIdentity ?? ids[1]
        return CaptureSessionTimeline(version: version, sourceDigest: "source", frames: ids,
            analyzed: analyzed ?? ids, observations: includesObservation ? [StoredFrame(frame)] : [],
            touches: [[1, 0.01, 0.4, 0.5]], count: 1, evidence: evidence)
    }
    private func outcomes(_ capture: CaptureSessionTimeline, source: String = "source",
                          signature: String = "pipeline") -> [Int: Outcome]? {
        capture.evidence?.validatedOutcomes(in: capture, sourceDigest: source, pipelineSignature: signature)
    }

    func testFailureRejectionAndUnsupportedPathsCannotBecomeEmptyEvidence() {
        XCTAssertEqual(Outcome.classify(succeeded: true, hasBall: false, hasMask: false,
            maskModel: true, rejected: false, direct: true), .empty)
        XCTAssertEqual(Outcome.classify(succeeded: false, hasBall: false, hasMask: false,
            maskModel: true, rejected: false, direct: true), .failed)
        XCTAssertEqual(Outcome.classify(succeeded: true, hasBall: false, hasMask: false,
            maskModel: true, rejected: true, direct: true), .rejected)
        XCTAssertEqual(Outcome.classify(succeeded: true, hasBall: false, hasMask: false,
            maskModel: true, rejected: false, direct: false), .notReusable)
        XCTAssertEqual(Outcome.classify(succeeded: true, hasBall: false, hasMask: false,
            maskModel: false, rejected: false, direct: true), .notReusable)
        XCTAssertEqual(Outcome.classify(succeeded: true, hasBall: true, hasMask: false,
            maskModel: true, rejected: false, direct: true), .notReusable)
        XCTAssertEqual(Outcome.classify(succeeded: true, hasBall: false, hasMask: true,
            maskModel: true, rejected: false, direct: true), .notReusable)
        XCTAssertEqual(Outcome.classify(succeeded: true, hasBall: true, hasMask: true,
            maskModel: true, rejected: false, direct: true), .observed)
    }

    func testCompleteEvidenceRoundTripsWithoutChangingMasksMarkersOrCount() throws {
        let original = fixture()
        let encoded = try PropertyListEncoder().encode(original)
        let decoded = try PropertyListDecoder().decode(CaptureSessionTimeline.self, from: encoded)
        XCTAssertEqual(outcomes(decoded), [0: .empty, 1: .observed, 2: .failed, 3: .rejected, 4: .notReusable])
        XCTAssertEqual(decoded.frames, original.frames)
        XCTAssertEqual(decoded.observations[0].values, original.observations[0].values)
        XCTAssertEqual(decoded.observations[0].alpha, original.observations[0].alpha)
        XCTAssertEqual(decoded.observations[0].identity, original.observations[0].identity)
        XCTAssertEqual(decoded.touches, original.touches)
        XCTAssertEqual(decoded.count, original.count)
    }

    func testLegacyCaptureStillDecodesButDoesNotQualify() throws {
        let encoded = try PropertyListEncoder().encode(fixture(version: 1))
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        plist.removeValue(forKey: "evidence")
        let legacy = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(CaptureSessionTimeline.self, from: legacy)
        XCTAssertNil(decoded.evidence)
        XCTAssertNil(outcomes(decoded))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.observations[0].alpha, Data([0, 64, 128, 255]))
    }

    func testChangedSourceBuildOrUnsupportedVersionFailsClosed() {
        XCTAssertNil(outcomes(fixture(), source: "another-source"))
        XCTAssertNil(outcomes(fixture(), signature: "another-build"))
        XCTAssertNil(outcomes(fixture(), signature: ""))
        XCTAssertNil(outcomes(fixture(version: 1)))
        XCTAssertNil(outcomes(fixture(version: 3)))
    }

    func testMissingDuplicateReorderedOrRetimedEvaluationsFailClosed() {
        let ids = (0..<5).map { identity($0) }
        XCTAssertNil(outcomes(fixture(evaluations: [])))
        XCTAssertNil(outcomes(fixture(analyzed: [ids[0], ids[1], ids[1], ids[3], ids[4]])))
        XCTAssertNil(outcomes(fixture(analyzed: [ids[1], ids[0], ids[2], ids[3], ids[4]])))
        var evaluations = fixture().evidence!.evaluations
        evaluations[0] = .init(identity: .init(index: 0, time: CMTime(value: 1, timescale: 60),
            width: 720, height: 1280, coordinates: "capture"), outcome: .empty)
        XCTAssertNil(outcomes(fixture(evaluations: evaluations)))
    }

    func testCoordinateMismatchAndInconsistentPositiveEvidenceFailClosed() {
        XCTAssertNil(outcomes(fixture(observationIdentity: identity(1, width: 1280))))
        XCTAssertNil(outcomes(fixture(outcomes: [.empty, .empty, .failed, .rejected, .notReusable])))
        XCTAssertNil(outcomes(fixture(includesObservation: false)))
    }

    func testSparseAnalysisDoesNotMarkUnanalyzedFramesAsEmpty() {
        let ids = [identity(0), identity(1), identity(4)]
        let capture = fixture(analyzed: ids, evaluations: [
            .init(identity: ids[0], outcome: .empty), .init(identity: ids[1], outcome: .observed),
            .init(identity: ids[2], outcome: .notReusable)])
        XCTAssertEqual(outcomes(capture), [0: .empty, 1: .observed, 4: .notReusable])
        XCTAssertNil(outcomes(capture)?[2])
        XCTAssertNil(outcomes(capture)?[3])
    }

    func testRepairedMaskOrUnknownCoordinatesCannotClaimOriginalObservation() throws {
        let encoded = try PropertyListEncoder().encode(fixture())
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        var observations = try XCTUnwrap(plist["observations"] as? [[String: Any]])
        observations[0]["repair"] = true; plist["observations"] = observations
        var data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertNil(outcomes(try PropertyListDecoder().decode(CaptureSessionTimeline.self, from: data)))
        plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        var frames = try XCTUnwrap(plist["frames"] as? [[String: Any]])
        frames[0]["coordinates"] = "unrecognised-coordinate-system"; plist["frames"] = frames
        data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertNil(outcomes(try PropertyListDecoder().decode(CaptureSessionTimeline.self, from: data)))
    }

    func testPersistStoresNewEvidenceWithoutChangingSessionValues() async throws {
        let original = fixture()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(UUID().uuidString.utf8).write(to: source)
        let digest = try SessionAnalysisStore.sourceDigest(source)
        let cached = URL.cachesDirectory.appendingPathComponent("SessionAnalysis-v1")
            .appendingPathComponent(digest + ".capture.plist")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: cached) }
        await CaptureSessionTimeline.persist(source: source, frames: original.frames,
            analyzed: original.analyzed, observations: original.observations.map(\.frame),
            touches: [.init(index: 1, time: 0.01, x: 0.4, y: 0.5)], count: 1,
            evidence: original.evidence)
        let decoded = try PropertyListDecoder().decode(CaptureSessionTimeline.self, from: Data(contentsOf: cached))
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.count, original.count)
        XCTAssertEqual(decoded.touches, original.touches)
        XCTAssertEqual(decoded.observations[0].alpha, original.observations[0].alpha)
        XCTAssertEqual(outcomes(decoded, source: digest), outcomes(original))
    }
}
