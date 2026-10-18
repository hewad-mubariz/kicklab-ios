import Foundation
import Testing
@testable import kicklab

struct GroundContactTests {
    private final class Resources {}
    private let bounce = [0.55, 0.60, 0.67, 0.75, 0.83, 0.89, 0.94, 0.95, 0.93, 0.86, 0.75, 0.62, 0.5]

    private func run(_ ys: [Double], policy: GroundContactPolicy = .supportedBoundary,
                     interval: Int = 33, offset: Double = 0, hand: Bool = false,
                     evidence: ((Int) -> FootContactEvidence?)? = nil,
                     floor: Double = 0.99,
                     height: (Int) -> Double = { _ in 0.1 }) -> CounterTrace {
        let counter = StreamingCounter(rejectsHandContact: { _ in hand }, recordTrace: true,
            footContactEvidence: evidence, allowsBodyContact: { _ in true }, groundPolicy: policy)
        for (i, y) in ys.enumerated() {
            counter.push(frameIndex: i, timestampMs: i*interval,
                ball: .init(frameIndex: i, timestampMs: i*interval, x: 0.5, y: y,
                            width: 0.1, height: height(i), confidence: 0.9),
                person: .init(x: 0.5, y: floor/2, width: 0.8, height: floor), cameraOffsetY: offset)
        }
        counter.flush()
        return counter.traceSnapshot()!
    }

    private func kick(at time: Int) -> FootContactEvidence {
        func sample(_ ms: Int, _ ballY: Double, _ ankleX: Double) -> FootContactRules.Sample {
            .init(timestampMs: ms, ballX: 0.5, ballY: ballY, width: 0.1, height: 0.1, confidence: 0.9,
                  ankles: [.left: .init(x: ankleX, y: 0.94, confidence: 0.9)],
                  hips: [.left: .init(x: 0.5, y: 0.5, confidence: 0.9)])
        }
        return .init(before: sample(time-66, 0.86, 0.45), contact: sample(time, 0.94, 0.5),
                     after: sample(time+66, 0.89, 0.55))
    }

    @Test(arguments: [8, 16, 33])
    func observedBoundaryCatchesABounceHiddenBySmoothing(interval: Int) throws {
        let old = run(bounce, policy: .legacyCenter, interval: interval)
        let current = run(bounce, interval: interval)
        #expect(old.touches.count == 1)
        #expect(current.touches.isEmpty)
        let decision = try #require(current.decisions.first?.value)
        #expect(decision.rejection == .groundBounce)
        #expect(decision.bodyContactAllowed == nil, "Foot proximity cannot bypass the ground gate")
        #expect(try #require(decision.observedBallBottom) >= 0.96)
        #expect(try old.replay() == old.touches)
        #expect(try current.replay() == current.touches)
        #expect(old.revision == "counter-v5" && current.revision == "counter-v7")
    }

    @Test func genuineLowFootEvidenceCanRecoverButHandVetoStillApplies() throws {
        let current = run(bounce, evidence: { kick(at: $0*33) })
        #expect(current.touches.count == 1)
        #expect(current.decisions.first?.value.footConfirmed == true)
        #expect(try current.replay() == current.touches)
        let hand = run(bounce, hand: true, evidence: { kick(at: $0*33) })
        #expect(hand.touches.isEmpty)
        #expect(hand.decisions.first?.value.rejection == .handContact)
    }

    @Test func isolatedBadPositionOrSizeCannotCreateGroundEvidence() {
        let high = bounce.map { $0-0.2 }
        var misplaced = high; misplaced[6] = 0.98
        #expect(run(high).touches.count == 1)
        #expect(run(misplaced).touches.count == 1)
        #expect(run(high, height: { $0 == 6 ? 0.8 : 0.1 }).touches.count == 1)
    }

    @Test func groundAndRawBallStayInTheSameCompensatedCoordinates() {
        for offset in [-0.2, 0, 0.2] {
            #expect(run(bounce, offset: offset).decisions.first?.value.rejection == .groundBounce)
            #expect(run(bounce.map { $0-0.2 }, offset: offset).touches.count == 1)
        }
    }

    @Test func bodyBoxOverlapNeedsMoreThanMissingKickEvidence() throws {
        let low = bounce.map { $0-0.3 }
        let broad = run(low, policy: .observedBoundary, floor: 0.69)
        let current = run(low, floor: 0.69)
        #expect(broad.touches.isEmpty)
        #expect(current.touches.count == 1, "A body-box bottom is not a ground plane")
        func stationary(at time: Int) -> FootContactEvidence {
            func sample(_ ms: Int, _ y: Double) -> FootContactRules.Sample {
                .init(timestampMs: ms, ballX: 0.5, ballY: y, width: 0.1, height: 0.1, confidence: 0.9,
                    ankles: [.left: .init(x: 0.45, y: 0.66), .right: .init(x: 0.55, y: 0.66)],
                    hips: [.left: .init(x: 0.45, y: 0.3), .right: .init(x: 0.55, y: 0.3)])
            }
            return .init(before: sample(time-66,0.5), contact: sample(time,0.64), after: sample(time+66,0.52))
        }
        let floor = run(low, evidence: { stationary(at: $0*33) }, floor: 0.69)
        #expect(floor.decisions.first?.value.rejection == .groundBounce,
                "A fully visible bounce beside two confidently stationary feet is still rejected")
        #expect(try current.replay() == current.touches)
        #expect(try floor.replay() == floor.touches)
    }

    @Test func lowToeTapsRetainEveryPreviousCountWithoutWeakeningFootMotionRules() throws {
        let oldURL = try #require(Bundle(for: Resources.self).url(forResource: "low-toe-taps-counter-v5", withExtension: "plist"))
        let regressedURL = try #require(Bundle(for: Resources.self).url(forResource: "low-toe-taps-counter-v6", withExtension: "plist"))
        let old = try PropertyListDecoder().decode(CounterTrace.self, from: Data(contentsOf: oldURL))
        let regressed = try PropertyListDecoder().decode(CounterTraceArchive.self, from: Data(contentsOf: regressedURL)).trace
        #expect(try old.replay().count == 143)
        #expect(try regressed.replay().count == 51)
        let bodies = Dictionary(uniqueKeysWithValues: old.decisions.map { ($0.value.frameIndex,$0.value) })
        let feet = Dictionary(uniqueKeysWithValues: regressed.decisions.map { ($0.value.frameIndex,$0.value) })
        let counter = StreamingCounter(config: old.config, rejectsHandContact: { bodies[$0]?.handRejected ?? false },
            recordTrace: true, footContactEvidence: { feet[$0]?.footEvidence ?? bodies[$0]?.footEvidence },
            allowsBodyContact: { bodies[$0]?.bodyContactAllowed ?? false })
        for operation in old.operations {
            if let i = operation.input {
                counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs, ball: i.ball, person: i.person,
                    cameraOffsetY: i.cameraOffsetY, reliable: i.reliable, sourceFrameIndex: i.sourceFrameIndex)
            } else { counter.flush() }
        }
        #expect(counter.touches == old.touches, "Preserve event identities, not just a similar count")
        #expect(try #require(counter.traceSnapshot()).replay() == counter.touches)
    }

    @Test func thirteenReviewedFloorBouncesCannotUseRecordedBodyApproval() throws {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "ground-bounces-counter", withExtension: "plist"))
        let archive = try PropertyListDecoder().decode(CounterTraceArchive.self, from: Data(contentsOf: url))
        #expect(try archive.trace.replay().count == 23, "Keep exact replay of the original v5 recording")
        let old = Dictionary(uniqueKeysWithValues: archive.trace.decisions.map { ($0.value.frameIndex, $0.value) })
        let jitterURL = try #require(Bundle(for: Resources.self).url(forResource: "ground-ankle-jitter", withExtension: "json"))
        let jitter = try JSONDecoder().decode(FootContactEvidence.self, from: Data(contentsOf: jitterURL))
        let counter = StreamingCounter(config: archive.trace.config,
            rejectsHandContact: { old[$0]?.handRejected ?? false }, recordTrace: true,
            // Actual phone pose from a formerly accepted floor bounce: a late
            // ankle jump must not rescue this contact once the ground gate runs.
            footContactEvidence: { $0 == 1672 ? jitter : old[$0]?.footEvidence },
            allowsBodyContact: { old[$0]?.bodyContactAllowed ?? false })
        for operation in archive.trace.operations {
            if let input = operation.input {
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: input.ball,
                    person: input.person, cameraOffsetY: input.cameraOffsetY, reliable: input.reliable,
                    sourceFrameIndex: input.sourceFrameIndex)
            } else { counter.flush() }
        }
        let trace = try #require(counter.traceSnapshot())
        let floors = [1098,1119,1132,1217,1390,1634,1655,1672,1685,1757,1791,1822,1856]
        for frame in floors {
            #expect(old[frame]?.rejection == nil && old[frame]?.bodyContactAllowed == true)
            #expect(trace.decisions.first { $0.value.frameIndex == frame }?.value.rejection == .groundBounce, "Floor frame \(frame)")
            #expect(!trace.touches.contains { $0.frameIndex == frame }, "Floor frame \(frame)")
        }
        for frame in [373,456,593,830,967,1897] {
            #expect(trace.touches.contains { $0.frameIndex == frame }, "Preserve reviewed chest/head/raised-leg contact \(frame)")
        }
        #expect(try trace.replay() == trace.touches)
    }
}
