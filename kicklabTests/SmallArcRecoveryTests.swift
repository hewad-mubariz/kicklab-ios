import Foundation
import Testing
@testable import kicklab

struct SmallArcRecoveryTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        var config: CounterConfig
        let operations: [CounterTrace.Operation]
        let feet: [Int: FootContactEvidence]
    }
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-short-arcs-20261027", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func run(recovery: Bool, evidence: Bool, hand: Bool = false, held: Bool = false,
                     roughFloor: Bool = false) throws -> CounterTrace {
        var f = try fixture()
        f.config.recoversMeasuredSmallArcs = recovery ? true : nil
        if roughFloor { f.config.groundTolerance = 0.15 }
        let counter = StreamingCounter(config: f.config,
            rejectsHandContact: { hand && $0 == 445 }, recordTrace: true,
            footContactEvidence: { frame in [445,469].contains(frame) && !evidence ? nil : f.feet[frame] },
            allowsBodyContact: { _ in true },
            handlingEvidence: { frame in
                guard held && frame == 445 else { return nil }
                return .init(contactMs: 14850, samples: [-100,-50,0,50,100].map { offset in
                    .init(timestampMs: 14850+offset, ball: .init(x: 0.5,y: 0.5),
                          width: 0.1,height: 0.06,confidence: 0.99,imageAspect: 0.5625,
                          wrists: [.left: .init(x: 0.46,y: 0.5), .right: .init(x: 0.54,y: 0.5)])
                })
            })
        for o in f.operations {
            if let i = o.input {
                counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs,
                    ball: i.ball, person: i.person, cameraOffsetY: i.cameraOffsetY,
                    reliable: i.reliable, sourceFrameIndex: i.sourceFrameIndex, player: i.player)
            }
        }
        counter.flush()
        let trace = try #require(counter.traceSnapshot())
        #expect(try trace.replay() == trace.touches)
        return trace
    }

    @Test func savedVisibleReboundRequiresPositiveFootEvidence() throws {
        let old = try run(recovery: false, evidence: true)
        let new = try run(recovery: true, evidence: true)
        #expect(!old.touches.contains { $0.frameIndex == 445 })
        #expect(new.touches.contains { $0.frameIndex == 445 })
        #expect(!old.touches.contains { $0.frameIndex == 469 })
        #expect(new.touches.contains { $0.frameIndex == 469 })
        #expect(Set(old.touches.map(\.frameIndex)).isSubset(of: Set(new.touches.map(\.frameIndex))))
    }

    @Test func failedProbePreservesTheFollowingLegalContact() throws {
        let old = try run(recovery: false, evidence: false)
        let new = try run(recovery: true, evidence: false)
        #expect(Set(old.touches.map(\.frameIndex)) == Set(new.touches.map(\.frameIndex)))
        #expect(new.touches.contains { $0.frameIndex == 456 })
        #expect(!new.touches.contains { $0.frameIndex == 445 })
    }

    @Test func smallArcAndRoughFloorShareOneRecordedFootCheck() throws {
        // This forces the body-box floor proxy to overlap the legal short arc.
        // Its positive foot proof must be reused, so the saved decision is exact
        // when replayed without running Vision a second time.
        let trace = try run(recovery: true, evidence: true, roughFloor: true)
        #expect(trace.touches.contains { $0.frameIndex == 445 })
        #expect(try trace.replay() == trace.touches)
    }

    @Test func smallArcRecoveryCannotBypassHandOrHoldingVetoes() throws {
        let hand = try run(recovery: true, evidence: true, hand: true)
        let held = try run(recovery: true, evidence: true, held: true)
        #expect(!hand.touches.contains { $0.frameIndex == 445 })
        #expect(!held.touches.contains { $0.frameIndex == 445 })
        #expect(hand.decisions.contains { $0.value.frameIndex == 445 && $0.value.rejection == .handContact })
        #expect(held.decisions.contains { $0.value.frameIndex == 445 && $0.value.rejection == .heldBall })
    }

    @Test func experimentalPolicyRetainsMeasuredFootRecoveryAndDefault() {
        let v22 = CountingPolicy.configured(arguments: ["--measured-foot-v22"])
        let v23 = CountingPolicy.configured(arguments: ["--small-arc-v23"])
        #expect(CountingPolicy.configured(arguments: []).body == .visibleFootV21)
        #if DEBUG
        #expect(v23.body == .smallArcV23 && v23.body.usesMeasuredFoot)
        for failure in [RestrictedTouchPolicy.Failure.handsUncertain, .handsNearBall, .missingPose, .invalidGeometry, .insufficientContactViews] {
            #expect(v23.body.allowsObservedLegRecovery(after: failure) == v22.body.allowsObservedLegRecovery(after: failure))
        }
        #endif
    }

    @Test func weakEarlyWobbleDoesNotSpendTheFollowingContactsEvidenceBudget() throws {
        struct BudgetFixture: Decodable {
            var config: CounterConfig
            let operations: [CounterTrace.Operation]
            let feet: [Int: FootContactEvidence]
            let ground: [Int: GroundContactEvidence]
        }
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-early-probe-budget-20261027", withExtension: "json"))
        var f = try JSONDecoder().decode(BudgetFixture.self, from: Data(contentsOf: url))
        f.config.recoversMeasuredSmallArcs = true
        var requested: [Int] = []
        let counter = StreamingCounter(config: f.config, recordTrace: true,
            footContactEvidence: { frame in requested.append(frame); return f.feet[frame] },
            // The saved iPhone case lost 549's missing-ball repair when 541
            // spent the shared 300 ms recheck budget only 266 ms beforehand.
            allowsBodyContact: { frame in frame != 549 || !requested.contains(541) },
            groundContactEvidence: { f.ground[$0] })
        for o in f.operations {
            if let i = o.input {
                counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs,
                    ball: i.ball, person: i.person, cameraOffsetY: i.cameraOffsetY,
                    reliable: i.reliable, sourceFrameIndex: i.sourceFrameIndex, player: i.player)
            }
        }
        counter.flush()
        #expect(!requested.contains(541))
        #expect(counter.touches.contains { $0.frameIndex == 549 })
        let trace = try #require(counter.traceSnapshot())
        #expect(try trace.replay() == trace.touches)
    }

    @Test func nearApexKickNeedsMeasuredFootLiftAndAnAirborneRelease() throws {
        struct Row: Decodable { let contactMs: Int; let samples: [FootPoseSample] }
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-shallow-approach-20261027", withExtension: "json"))
        let row = try #require(JSONDecoder().decode([Row].self, from: Data(contentsOf: url)).first)
        func contact(_ samples: [FootPoseSample], shallow: Bool) -> Int? {
            ObservedLegContactRules.contactTime(samples, at: row.contactMs,
                usesTemporalEvidence: true, usesCadenceWindow: true, allowsNearSupportFoot: true,
                usesImageSupport: true, allowsTurningHip: true, allowsLowToeDeparture: true,
                allowsShallowApproach: shallow)
        }
        #expect(contact(row.samples, shallow: false) == nil)
        #expect(contact(row.samples, shallow: true) == 15716)
        let noRelease = row.samples.filter { $0.pose.timestampMs <= 15716 }
        #expect(contact(noRelease, shallow: true) == nil)
        let stationary = row.samples.map { value in
            var sample = value
            sample.landmarks = row.samples[0].landmarks
            return sample
        }
        #expect(contact(stationary, shallow: true) == nil)
        let weak = row.samples.map { value in
            var sample = value
            for side in BodySide.allCases {
                if var ankle = sample.landmarks[side.ankle] {
                    ankle.confidence = 0.2
                    sample.landmarks[side.ankle] = ankle
                }
            }
            return sample
        }
        #expect(contact(weak, shallow: true) == nil)
    }
}
