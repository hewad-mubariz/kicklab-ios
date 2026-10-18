import Foundation
import Testing
@testable import kicklab

struct PlantedFeetTests {
    private final class Resources {}

    private func evidence(interval: Int = 33, movingFoot: Bool = false,
                          translation: Bool = false, jitter: Bool = false,
                          clearApproach: Bool = true, highContact: Bool = false,
                          confidence: Double = 0.9) -> GroundContactEvidence {
        let samples = (-8...3).map { i -> GroundContactEvidence.Sample in
            let t = i*interval
            let shift = translation ? Double(i)*0.01 : 0
            let kick = movingFoot && i >= -2 ? 0.06 : 0
            let noise = jitter && i == 0 ? 0.025 : 0
            let ballY = (highContact ? 0.55 : 0.85) - (clearApproach ? Double(abs(t))*0.0015 : 0)
            return .init(timestampMs: 1000+t, ballX: 0.5, ballY: ballY+shift,
                width: 0.18, height: 0.1, confidence: 0.9, imageAspect: 0.5625,
                ankles: [.left: .init(x: 0.42, y: 0.84+shift-kick+noise, confidence: confidence),
                         .right: .init(x: 0.58, y: 0.84+shift, confidence: confidence)],
                hips: [.left: .init(x: 0.45, y: 0.5+shift, confidence: confidence),
                       .right: .init(x: 0.55, y: 0.5+shift, confidence: confidence)])
        }
        return .init(contactMs: 1000, samples: samples)
    }

    @Test(arguments: [25, 30, 33, 40])
    func plantedFeetUseElapsedTimeAndTolerateAnIsolatedPoseJitter(interval: Int) {
        #expect(evidence(interval: interval).confirmsPlantedFeet)
        #expect(evidence(interval: interval, jitter: true).confirmsPlantedFeet)
    }

    @Test func RealMovementOrUncertainPoseCannotEstablishPlantedFeet() {
        #expect(!evidence(movingFoot: true).confirmsPlantedFeet)
        #expect(!evidence(translation: true).confirmsPlantedFeet,
                "A whole-body jump must not disappear when subtracting pelvis translation")
        #expect(!evidence(confidence: 0.4).confirmsPlantedFeet)
        #expect(!evidence(clearApproach: false).confirmsPlantedFeet,
                "Small taps with the ball continuously close to a foot are inconclusive")
        #expect(!evidence(highContact: true).confirmsPlantedFeet)
    }

    @Test func MissingHistoryGapsAndInvalidCoordinatesAreInconclusive() {
        let e = evidence()
        #expect(!GroundContactEvidence(contactMs: e.contactMs, samples: Array(e.samples.suffix(7))).confirmsPlantedFeet)
        #expect(!GroundContactEvidence(contactMs: e.contactMs, samples: Array(e.samples.prefix(9))).confirmsPlantedFeet)
        #expect(!GroundContactEvidence(contactMs: e.contactMs,
            samples: e.samples.filter { !(850...970).contains($0.timestampMs) }).confirmsPlantedFeet)
        #expect(!GroundContactEvidence(contactMs: e.contactMs, samples: e.samples+[e.samples[0]]).confirmsPlantedFeet)
        let s = e.samples[4]
        let invalid = GroundContactEvidence.Sample(timestampMs: s.timestampMs, ballX: .nan, ballY: s.ballY,
            width: s.width, height: s.height, confidence: s.confidence, imageAspect: s.imageAspect,
            ankles: s.ankles, hips: s.hips)
        var samples = e.samples; samples[4] = invalid
        #expect(!GroundContactEvidence(contactMs: e.contactMs, samples: samples).confirmsPlantedFeet)
    }

    private func resource(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    private func run(_ old: CounterTrace, poses: [Int: GroundContactEvidence]) throws -> CounterTrace {
        let decisions = Dictionary(uniqueKeysWithValues: old.decisions.map { ($0.value.frameIndex,$0.value) })
        let counter = StreamingCounter(config: old.config,
            rejectsHandContact: { decisions[$0]?.handRejected ?? false }, recordTrace: true,
            footContactEvidence: { decisions[$0]?.footEvidence },
            allowsBodyContact: { decisions[$0]?.bodyContactAllowed ?? false },
            groundContactEvidence: { poses[$0] })
        for operation in old.operations {
            if let i = operation.input {
                counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs, ball: i.ball,
                    person: i.person, cameraOffsetY: i.cameraOffsetY, reliable: i.reliable,
                    sourceFrameIndex: i.sourceFrameIndex)
            } else { counter.flush() }
        }
        let trace = try #require(counter.traceSnapshot())
        #expect(trace.revision == CounterTrace.currentRevision)
        #expect(try trace.replay() == trace.touches)
        return trace
    }

    @Test func AllSeventeenReviewedVisibleFloorBouncesAreRejected() throws {
        let old = try PropertyListDecoder().decode(CounterTrace.self,
            from: resource("visible-ground-bounces-counter-v7", "plist"))
        let poses = try JSONDecoder().decode([Int: GroundContactEvidence].self,
            from: resource("visible-ground-bounces-pose", "json"))
        #expect(try old.replay().count == 17)
        let current = try run(old, poses: poses)
        #expect(current.touches.isEmpty)
        for touch in old.touches {
            let decision = try #require(current.decisions.first { $0.value.frameIndex == touch.frameIndex }?.value)
            #expect(decision.rejection == .groundBounce, "Floor contact \(touch.frameIndex)")
        }
        // Four failures never reached the previous estimated-floor gate; others
        // lacked strict three-frame kick evidence because of motion-blurred size.
        for frame in [742,1080,1216,1270] {
            #expect(old.decisions.first { $0.value.frameIndex == frame }?.value.footConfirmed == nil)
            #expect(current.decisions.first { $0.value.frameIndex == frame }?.value.plantedFeetConfirmed == true)
        }
    }

    @Test func EveryRecoveredToeTapIsPreservedWithNewGroundEvidence() throws {
        let old = try PropertyListDecoder().decode(CounterTrace.self,
            from: resource("low-toe-taps-counter-v7", "plist"))
        let poses = try JSONDecoder().decode([Int: GroundContactEvidence].self,
            from: resource("low-toe-taps-ground-pose", "json"))
        #expect(try old.replay().count == 171)
        let current = try run(old, poses: poses)
        #expect(current.touches == old.touches, "Preserve all event identities, times and positions")
        #expect(current.decisions.contains { $0.value.groundEvidence != nil },
                "Exercise the new gate rather than bypassing it in this regression")
    }

    @Test func SparseReviewedFloorContactsAreRejectedWithoutChangingOtherTouches() throws {
        let old = try PropertyListDecoder().decode(CounterTrace.self,
            from: resource("sparse-floor-bounces-counter-v8", "plist"))
        let poses = try JSONDecoder().decode([Int: GroundContactEvidence].self,
            from: resource("sparse-floor-bounces-pose", "json"))
        #expect(try old.replay().count == 19, "Keep exact v8 replay")
        for frame in [1720, 1731] {
            let evidence = try #require(poses[frame])
            #expect(!evidence.confirmsPlantedFeet)
            #expect(evidence.confirmsPlantedFeet(corroboratingWeakAnkles: true))
        }
        let current = try run(old, poses: poses)
        let retained = old.touches.filter { ![1720,1731].contains($0.frameIndex) }
        #expect(current.touches.map(\.frameIndex) == retained.map(\.frameIndex))
        #expect(current.touches.map(\.timestampMs) == retained.map(\.timestampMs))
        for frame in [1720,1731] {
            #expect(current.decisions.first { $0.value.frameIndex == frame }?.value.rejection == .groundBounce)
        }
    }

    @Test func CorroborationNeverInventsAMissingOrContradictoryAnkle() throws {
        let poses = try JSONDecoder().decode([Int: GroundContactEvidence].self,
            from: resource("sparse-floor-bounces-pose", "json"))
        let e = try #require(poses[1731])
        let index = try #require(e.samples.firstIndex { $0.timestampMs == e.contactMs-66 })
        let original = e.samples[index]
        for kind in ["missing", "weak", "moving"] {
            var ankles = original.ankles
            let a = try #require(ankles[.right])
            switch kind {
            case "missing": ankles.removeValue(forKey: .right)
            case "weak": ankles[.right] = .init(x: a.x, y: a.y, confidence: 0.29)
            default: ankles[.right] = .init(x: a.x, y: a.y-0.08, confidence: a.confidence)
            }
            var samples = e.samples
            samples[index] = .init(timestampMs: original.timestampMs, ballX: original.ballX,
                ballY: original.ballY, width: original.width, height: original.height,
                confidence: original.confidence, imageAspect: original.imageAspect,
                ankles: ankles, hips: original.hips)
            #expect(!GroundContactEvidence(contactMs: e.contactMs, samples: samples)
                .confirmsPlantedFeet(corroboratingWeakAnkles: true), "\(kind) ankle stays inconclusive")
        }
        #expect(!GroundContactEvidence(contactMs: e.contactMs,
            samples: e.samples.filter { $0.timestampMs != original.timestampMs })
            .confirmsPlantedFeet(corroboratingWeakAnkles: true), "Do not bridge an absent observation")
        for uncertain in [evidence(movingFoot: true), evidence(translation: true),
                          evidence(confidence: 0.4), evidence(clearApproach: false), evidence(highContact: true)] {
            #expect(!uncertain.confirmsPlantedFeet(corroboratingWeakAnkles: true))
        }
        #expect(!GroundContactEvidence(contactMs: 0, samples: [])
            .confirmsPlantedFeet(corroboratingWeakAnkles: true))
    }
}
