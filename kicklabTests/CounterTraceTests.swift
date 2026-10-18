import Foundation
import Testing
@testable import kicklab

struct CounterTraceTests {
    private let arc = [0.35,0.4,0.46,0.53,0.6,0.67,0.73,0.76,0.74,0.70,0.63,0.55,0.46,0.38,0.32]
    private func feed(_ c: StreamingCounter, start: Int = 0, jump: Bool = false) {
        for (i,y) in arc.enumerated() {
            let f = start + i, time = 987_654_321 + f * 33 + (jump && i >= 8 ? 1800 : 0)
            c.push(frameIndex: f, timestampMs: time,
                ball: i == 7 ? nil : .init(frameIndex: f, timestampMs: time, x: 0.5, y: y,
                    width: 0.05, height: 0.03, confidence: 0.9),
                person: .init(x: 0.5, y: 0.45, width: 0.8, height: 0.9),
                cameraOffsetY: 0.17, sourceFrameIndex: f * 2)
        }
    }
    private func roundTrip(_ trace: CounterTrace) throws -> CounterTrace {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try PropertyListDecoder().decode(CounterTrace.self, from: encoder.encode(trace))
    }

    @Test func exactReplayKeepsMissesPlayerGeometryOffsetsAndSourceIdentity() throws {
        let c = StreamingCounter(recordTrace: true); feed(c); c.flush(); c.flush()
        let trace = try roundTrip(#require(c.traceSnapshot()))
        #expect(c.count == 1)
        #expect(try trace.replay() == c.touches)
        let miss = try #require(trace.operations[7].input)
        #expect(miss.ball == nil)
        #expect(miss.person != nil)
        #expect(miss.cameraOffsetY == 0.17)
        #expect(miss.timestampMs == 987_654_552)
        #expect(miss.sourceFrameIndex == 14)
        let finalOperationsAreFlushes = trace.operations.suffix(2).allSatisfy { $0.flush }
        #expect(finalOperationsAreFlushes)
    }

    @Test func cameraStallsAndShakyFramesReplayWithoutCompletingOldArcs() throws {
        let c = StreamingCounter(recordTrace: true); feed(c, jump: true)
        c.push(frameIndex: 15, timestampMs: 987_657_000, ball: nil, person: nil,
               cameraOffsetY: .nan, reliable: false)
        feed(c, start: 20); c.flush()
        let trace = try roundTrip(#require(c.traceSnapshot()))
        #expect(c.count == 1)
        #expect(trace.decisions.contains { $0.value.rejection == .trackLost })
        #expect(try trace.replay() == c.touches)
    }

    @Test func handVerdictsAreReplayedWithoutCallingTheVerifierAgain() throws {
        var calls = 0
        let c = StreamingCounter(rejectsHandContact: { _ in calls += 1; return calls == 1 }, recordTrace: true)
        feed(c); feed(c, start: arc.count); c.flush()
        #expect(calls == 2)
        #expect(c.count == 1)
        let trace = try roundTrip(#require(c.traceSnapshot()))
        #expect(trace.decisions.contains { $0.value.rejection == .handContact && $0.value.handRejected == true })
        #expect(try trace.replay() == c.touches)
        #expect(calls == 2)
    }

    @Test func boundedDiagnosticsNeverStopCountingOrClaimCompleteReplay() throws {
        let c = StreamingCounter(recordTrace: true, traceLimit: 7); feed(c); c.flush()
        let trace = try #require(c.traceSnapshot())
        #expect(c.count == 1)
        #expect(!trace.complete)
        #expect(trace.operations.count == 7)
        #expect(throws: CounterTrace.ReplayError.self) { try trace.replay() }
    }

    @Test func bodyFilterRejectsTorsoAndReplaysBothVerdicts() throws {
        var calls = 0
        let c = StreamingCounter(recordTrace: true, allowsBodyContact: { _ in
            calls += 1; return calls != 1
        })
        feed(c); feed(c, start: arc.count); c.flush()
        #expect(calls == 2)
        #expect(c.count == 1)
        let trace = try roundTrip(#require(c.traceSnapshot()))
        #expect(trace.usesBodyVerifier == true)
        #expect(trace.decisions.contains { $0.value.rejection == .disallowedBodyContact && $0.value.bodyContactAllowed == false })
        #expect(trace.decisions.contains { $0.value.rejection == nil && $0.value.bodyContactAllowed == true })
        #expect(try trace.replay() == c.touches)
        #expect(calls == 2)
    }

    @Test func bodyEligibilityCannotOverrideHandRejection() throws {
        let c = StreamingCounter(rejectsHandContact: { _ in true }, recordTrace: true,
                                 allowsBodyContact: { _ in true })
        feed(c); c.flush()
        #expect(c.count == 0)
        let trace = try roundTrip(#require(c.traceSnapshot()))
        #expect(trace.decisions.contains { $0.value.rejection == .handContact && $0.value.bodyContactAllowed == true })
        #expect(try trace.replay() == c.touches)
    }

    @Test func missingBodyEvidenceCannotBeAssumedLegal() throws {
        let c = StreamingCounter(recordTrace: true, allowsBodyContact: { _ in false })
        feed(c); c.flush()
        let t = try #require(c.traceSnapshot())
        let changed = CounterTrace(revision: t.revision, config: t.config, usesHandVerifier: false,
            usesBodyVerifier: true, complete: t.complete, operations: t.operations, decisions: [], touches: t.touches)
        #expect(throws: CounterTrace.ReplayError.self) { try changed.replay() }
    }

    @Test func earlierTracesWithoutBodyFilterRemainDecodable() throws {
        let c = StreamingCounter(recordTrace: true); feed(c); c.flush()
        let t = try #require(c.traceSnapshot())
        let data = try JSONEncoder().encode(t)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["usesBodyVerifier"] == nil)
        let decoded = try JSONDecoder().decode(CounterTrace.self, from: data)
        #expect(decoded.usesBodyVerifier == nil)
        #expect(decoded.diagnostics == nil)
        #expect(try decoded.replay() == c.touches)
    }

    @Test func debugHandAnnotationCannotChangeTheRejectingGateOrCount() throws {
        var calls = 0
        let c = StreamingCounter(recordTrace: true, allowsBodyContact: { _ in false },
            diagnoseContact: { decision, ball in
                calls += 1
                return .init(frameIndex: decision.frameIndex, time: Double(decision.timestampMs) / 1000,
                    rejection: decision.rejection, handConfirmed: true, bodyFailure: .torsoOverlap, ball: ball)
            })
        feed(c); c.flush()
        let trace = try roundTrip(#require(c.traceSnapshot()))
        #expect(calls == 1)
        #expect(c.count == 0)
        let event = try #require(trace.diagnostics?.first)
        #expect(event.title == "Hand touch")
        #expect(event.detail == "Body filter · Ball overlaps torso")
        #expect(trace.decisions.first?.value.rejection == .disallowedBodyContact)
        #expect(trace.decisions.first?.value.handRejected == nil)
        #expect(c.latestDiagnostic == event)
        #expect(try trace.replay() == c.touches)
        #expect(calls == 1, "Trace replay does not run visual diagnostics")
    }

    @Test func debugContactPositionsUseOriginalPixelsAndPlaybackClock() throws {
        let c = StreamingCounter(recordTrace: true, diagnoseContact: { decision, ball in
            .init(frameIndex: decision.frameIndex, time: Double(decision.timestampMs) / 1000,
                  rejection: decision.rejection, handConfirmed: false, bodyFailure: nil, ball: ball)
        })
        feed(c); c.flush()
        let trace = try #require(c.traceSnapshot())
        let event = try #require(trace.diagnostics?.first)
        let input = try #require(trace.operations.compactMap(\.input).first { $0.frameIndex == event.frameIndex })
        #expect(event.ball == input.ball, "Do not draw using motion-compensated coordinates")
        let relative = event.relative(to: 987654)
        #expect(relative.time == event.time - 987654)
        #expect(TouchDebugEvent.visible(in: [relative], at: relative.time - 0.001) == nil)
        #expect(TouchDebugEvent.visible(in: [relative], at: relative.time + 0.2) == relative)
        #expect(TouchDebugEvent.visible(in: [relative], at: relative.time + 1) == nil)
        #expect(try trace.replay() == c.touches)
    }

    @Test func unfinishedAndIncompatibleTracesCannotPassVerification() throws {
        let c = StreamingCounter(recordTrace: true); feed(c)
        #expect(throws: CounterTrace.ReplayError.self) { try c.traceSnapshot()!.replay() }
        c.flush(); let t = try #require(c.traceSnapshot())
        let changed = CounterTrace(revision: "different-algorithm", config: t.config, usesHandVerifier: t.usesHandVerifier,
            complete: t.complete, operations: t.operations, decisions: t.decisions, touches: t.touches)
        #expect(throws: CounterTrace.ReplayError.self) { try changed.replay() }
    }

    @Test func missingHandEvidenceCannotBeAssumedLegal() throws {
        let c = StreamingCounter(rejectsHandContact: { _ in true }, recordTrace: true); feed(c); c.flush()
        let t = try #require(c.traceSnapshot())
        let changed = CounterTrace(revision: t.revision, config: t.config, usesHandVerifier: true,
            complete: t.complete, operations: t.operations, decisions: [], touches: t.touches)
        #expect(throws: CounterTrace.ReplayError.self) { try changed.replay() }
    }

    @Test(arguments: [false, true])
    func realRecordedFirstKickDecisionsAndCustomConfigurationSurviveSerialization(legacy: Bool) throws {
        let url = try #require(Bundle(for: Fixture.self).url(forResource: "contact-counter-34dd", withExtension: "json"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        struct FootFixture: Decodable { let name: String; let evidence: FootContactEvidence }
        let footURL = try #require(Bundle(for: Fixture.self).url(forResource: "foot-ground-evidence", withExtension: "json"))
        let foot = try #require(JSONDecoder().decode([FootFixture].self, from: Data(contentsOf: footURL))
            .first { $0.name == "sep30-284" }?.evidence)
        var config = CounterConfig(); config.minFallBallHeights = 0.13
        let policy: GroundContactPolicy = legacy ? .legacyCenter : .observedBoundary
        // The second kick is close to the floor: use its recorded positive foot
        // evidence before checking that the hand veto still wins in both versions.
        let c = StreamingCounter(config: config, rejectsHandContact: { $0 == 284 }, recordTrace: true,
            footContactEvidence: { $0 == 284 ? foot : nil }, groundPolicy: policy)
        let control = StreamingCounter(config: config, rejectsHandContact: { $0 == 284 },
            footContactEvidence: { $0 == 284 ? foot : nil }, groundPolicy: policy)
        for row in raw["rows"] as! [[String: Any]] {
            let f = row["frame"] as! Int, ms = Int((row["time"] as! Double) * 1000)
            let ball = (row["ball"] as? [Double]).map { BallObservation(frameIndex: f, timestampMs: ms,
                x: $0[1], y: $0[2], width: $0[3], height: $0[4], confidence: $0[0]) }
            let person = (row["person"] as? [Double]).map { PersonBox(x: $0[1], y: $0[2], width: $0[3], height: $0[4]) }
            for counter in [c, control] { counter.push(frameIndex: f, timestampMs: ms, ball: ball, person: person,
                cameraOffsetY: row["offset"] as? Double ?? 0, reliable: row["reliable"] as? Bool ?? true, sourceFrameIndex: f) }
        }
        c.flush(); control.flush()
        let trace = try roundTrip(#require(c.traceSnapshot()))
        #expect(trace.config == config)
        #expect(c.touches.map(\.frameIndex) == [247])
        #expect(c.touches == control.touches)
        #expect(try trace.replay() == c.touches)
        // The unsupported acquisition also reaches the observed ground band;
        // v6 rejects it at the earlier ground gate without requesting foot pose.
        #expect(trace.decisions.contains { $0.value.frameIndex == 70
            && $0.value.rejection == (legacy ? .unsupportedByDetection : .groundBounce) })
        #expect(trace.decisions.contains { $0.value.frameIndex == 284 && $0.value.rejection == .handContact })
    }

    @Test func diagnosticArchiveKeepsLiveAndFileAnalysisSeparate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionAnalysisStore(folder: folder)
        let c = StreamingCounter(recordTrace: true); feed(c); c.flush(); let t = try #require(c.traceSnapshot())
        for mode in [CounterTraceArchive.Mode.capture, .file] {
            await store.saveCounterTrace(.init(sourceDigest: "fixture", pipelineSignature: "test", mode: mode,
                timeOriginSeconds: mode == .capture ? 987654 : 0, trace: t))
        }
        let capture = try #require(await store.loadCounterTrace(sourceDigest: "fixture", mode: .capture))
        let file = try #require(await store.loadCounterTrace(sourceDigest: "fixture", mode: .file))
        #expect(capture.timeOriginSeconds == 987654)
        #expect(file.timeOriginSeconds == 0)
        #expect(try capture.trace.replay() == c.touches)
        #expect(try file.trace.replay() == c.touches)
    }
    private final class Fixture {}
}
