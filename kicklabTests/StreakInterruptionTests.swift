import XCTest
@testable import kicklab

final class StreakInterruptionTests: XCTestCase {
    private func grip(at time: Int, missingWrist: Bool = false) -> BallHandlingEvidence {
        .init(contactMs: time, samples: [-133,-67,0,67,133].map { offset in
            .init(timestampMs: time+offset, ball: .init(x: 0.5,y: 0.6),
                width: 0.18,height: 0.1,confidence: 0.95,imageAspect: 0.5625,
                wrists: missingWrist ? [.left: .init(x: 0.4,y: 0.56)] :
                    [.left: .init(x: 0.4,y: 0.56), .right: .init(x: 0.6,y: 0.56)])
        }, bridgesGripJitter: true)
    }

    func testOnlySustainedGripAfterTouchEndsRun() {
        XCTAssertEqual(StreakInterruption.held(grip(at: 2000), after: 1000)?.kind, .heldBall)
        XCTAssertNil(StreakInterruption.held(grip(at: 2000, missingWrist: true), after: 1000))
        XCTAssertNil(StreakInterruption.held(grip(at: 2000), after: 1950), "A grip before the kick/release cannot invalidate it")
        var short = grip(at: 2000)
        short = .init(contactMs: short.contactMs, samples: Array(short.samples[1...3]))
        XCTAssertNil(StreakInterruption.held(short, after: 1000), "Brief hand proximity is not a sustained catch")
    }

    func testNoOpeningPenaltyBoundedProbesAndResumeAfterNewTouch() {
        var schedule = StreakInterruptionSchedule()
        XCTAssertFalse(schedule.shouldProbe(now: 1000, lastTouchMs: nil, hasBall: true))
        schedule.end(at: 1100) // Hand-held start.
        XCTAssertTrue(schedule.hasOpenRun(lastTouchMs: 2000))
        var probes = 0
        for time in 2200..<3200 where schedule.shouldProbe(now: time, lastTouchMs: 2000, hasBall: true) { probes += 1 }
        XCTAssertEqual(probes, 4)
        schedule.end(at: 3200)
        XCTAssertFalse(schedule.shouldProbe(now: 5000, lastTouchMs: 2000, hasBall: true))
        XCTAssertTrue(schedule.shouldProbe(now: 6200, lastTouchMs: 6000, hasBall: true))
        XCTAssertFalse(schedule.shouldProbe(now: 7000, lastTouchMs: 6000, hasBall: false))
        XCTAssertTrue(schedule.hasOpenRun(lastTouchMs: 6000), "Missing ball/long silence isn't itself a foul")
    }

    func testFloorBoundaryNeedsPositivePoseEvidenceAndCannotOverrideConfirmedFoot() throws {
        let samples = (-8...3).map { i -> GroundContactEvidence.Sample in
            .init(timestampMs: 1000+i*33, ballX: 0.5, ballY: 0.85-Double(abs(i*33))*0.0015,
                width: 0.18,height: 0.1,confidence: 0.95,imageAspect: 0.5625,
                ankles: [.left: .init(x: 0.42,y: 0.84), .right: .init(x: 0.58,y: 0.84)],
                hips: [.left: .init(x: 0.45,y: 0.5), .right: .init(x: 0.55,y: 0.5)])
        }
        let evidence = GroundContactEvidence(contactMs: 1000, samples: samples)
        let rejected = CounterDecision(frameIndex: 30, timestampMs: 1000, rejection: .groundBounce)
        let interruption = try XCTUnwrap(StreakInterruption.floor(rejected, evidence: evidence,
            policy: .corroboratedFeet, cadenceAware: true))
        XCTAssertEqual(interruption.kind, .groundContact)
        let missing = GroundContactEvidence(contactMs: 1000, samples: [])
        XCTAssertNil(StreakInterruption.floor(rejected, evidence: missing, policy: .corroboratedFeet, cadenceAware: true))
        let foot = CounterDecision(frameIndex: 30, timestampMs: 1000, rejection: .groundBounce, footConfirmed: true)
        XCTAssertNil(StreakInterruption.floor(foot, evidence: evidence, policy: .corroboratedFeet, cadenceAware: true))
        let uncertain = CounterDecision(frameIndex: 30, timestampMs: 1000, rejection: .unresolvedLowContact)
        XCTAssertNil(StreakInterruption.floor(uncertain, evidence: evidence, policy: .corroboratedFeet, cadenceAware: true))
    }

    func testInterContactHoldChangesEvidenceWithoutChangingTrainingTouches() throws {
        let baseline = StreamingCounter(recordTrace: true)
        var probes = 0
        let changed = StreamingCounter(recordTrace: true, streakHandlingEvidence: { [self] now, last in
            probes += 1
            // A hold during the pause, not during either juggling arc.
            return (1100...1500).contains(now) ? grip(at: now-133) : nil
        })
        let arc = [0.35,0.4,0.46,0.53,0.6,0.67,0.73,0.76,0.74,0.70,0.63,0.55,0.46,0.38,0.32]
        let ys = arc + Array(repeating: 0.32, count: 40) + arc
        for (frame,y) in ys.enumerated() {
            for counter in [baseline, changed] {
                counter.push(frameIndex: frame, timestampMs: frame*33,
                    ball: .init(frameIndex: frame, timestampMs: frame*33, x: 0.5,y: y,width: 0.05,height: 0.03,confidence: 0.9),
                    person: .init(x: 0.5,y: 0.45,width: 0.8,height: 0.9))
            }
        }
        baseline.flush(); changed.flush()
        XCTAssertEqual(changed.count, 2)
        XCTAssertEqual(changed.touches, baseline.touches)
        XCTAssertEqual(changed.reviewEvidence.observations.map(\.kind), [.heldBall])
        XCTAssertLessThan(probes, 9)
        let trace = try XCTUnwrap(changed.traceSnapshot())
        XCTAssertEqual(try trace.replay(), baseline.touches)
        XCTAssertEqual(trace.streakInterruptions?.count, 1)
        let times = changed.touches.map { Double($0.timestampMs)/1000 }
        let review = try XCTUnwrap(LeaderboardTouchReview.make(evidence: changed.reviewEvidence, touchTimes: times, duration: 3))
        XCTAssertEqual(RankedStreakProposal.suggest(touchTimes: times, boundaries: review.streakBoundaries, duration: 3)?.count, 1)
    }
}
