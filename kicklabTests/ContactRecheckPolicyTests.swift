import Testing
@testable import kicklab

struct ContactRecheckPolicyTests {
    @Test func lowContactProofIsOnlyRequiredWhenOriginalImpactTrackingHasAGap() {
        func sparse(_ offsets: [Int], missing: [Int] = [-33,0]) -> Bool {
            GroundContactEvidence.hasImpactTrackingGap(contactMs: 1000,
                originalTimestampsMs: offsets.map { 1000+$0 },
                missingBallTimestampsMs: missing.map { 1000+$0 })
        }
        // Real two-bounce original windows. Repairing these images must not
        // change the provenance used to choose the extra foot-proof route.
        #expect(sparse([-300,-267,-234,-200,-167,-134,-100,0,200]))
        #expect(sparse([-300,-266,-233,-200,-166,-133,-100,34,67,100]))
        // Low juggling at 30 Hz, including one missing image, stays eligible.
        #expect(!sparse([-100,-67,-34,0,33,66,100]))
        #expect(!sparse([-100,-67,-34,33,66,100]))
        #expect(!sparse([-100,-67,0,33,66,100]))
        #expect(!sparse([-100,-66,-33,0,34,67,100]))
        #expect(!sparse([-300,-100,-67,-34,0,33,66,100]))
        // Reviewed legal walkthrough toe tap: capture skipped exposures, but
        // every admitted image contained the ball. Do not call it tracking loss.
        #expect(!sparse([-300,-166,-133,-100,-66,0,100,167], missing: []))
        #expect(!sparse([-100,0,100], missing: [33]))
        #expect(!sparse([-100,0,100], missing: [33,33]))
        #expect(sparse([-100,0,100], missing: [33,66]))
    }
    @Test func impactWindowIncludesBothSidesWithoutSharingRepairedIdentityHints() {
        let policy = ContactRecheckPolicy()
        let observed: [ContactFrameWindow.Stamp] = [.init(index: 797, timestampMs: 900),
            .init(index: 800, timestampMs: 1000), .init(index: 806, timestampMs: 1200)]
        let missing = [(-67,798),(-34,799),(33,801),(66,802),(100,803)].map {
            ContactFrameWindow.Stamp(index: $0.1, timestampMs: 1000+$0.0)
        }
        // +33 lacks an independent release within 134 ms; +66 is admissible.
        #expect(policy.impactWindow(contactMs: 1000, missing: missing, observed: observed) == [799,802,798])
        let secondMissing = [(-66,840),(-33,841),(0,842)].map {
            ContactFrameWindow.Stamp(index: $0.1, timestampMs: 1000+$0.0)
        }
        #expect(policy.impactWindow(contactMs: 1000, missing: secondMissing,
            observed: [.init(index: 839,timestampMs: 900), .init(index: 843,timestampMs: 1034)]) == [842,841,840])
        #expect(policy.impactWindow(contactMs: 1000, missing: missing, observed: [observed[0],observed[1]]).allSatisfy { $0 < 800 })
        #expect(policy.impactWindow(contactMs: 1000, missing: secondMissing,
            observed: [.init(index: 839,timestampMs: 700), .init(index: 843,timestampMs: 1300)]).isEmpty)
        #expect(policy.permitsImpactWindow(source: 1, now: 100, lastSource: 0.7, lastWall: 99.7))
        #expect(!policy.permitsImpactWindow(source: 1, now: 100, lastSource: 0.8, lastWall: 99.7))
        #expect(!policy.permitsImpactWindow(source: 1, now: 100, lastSource: 0.7, lastWall: 99.8))
    }
    @Test func impactRetryIsBoundedByIdentityAgeQueueAndWallTime() {
        let policy = ImpactGapRecoveryPolicy()
        #expect(policy.permits(source: 1, hintTime: 0.967, now: 100.21, due: 100,
            lastSource: 0.5, lastWall: 99.5, outstanding: 0, budget: 0.08))
        for (hint, now, depth, last) in [(0.8,100.21,0,99.5),(0.967,100.251,0,99.5),
                                       (0.967,100.21,5,99.5),(0.967,100.21,0,100.1)] {
            #expect(!policy.permits(source: 1, hintTime: hint, now: now, due: 100,
                lastSource: 0.5, lastWall: last, outstanding: depth, budget: 0.08))
        }
        #expect(policy.accepts(score: 0.9, completed: 100.3, due: 100))
        #expect(!policy.accepts(score: 0.69, completed: 100.3, due: 100))
        #expect(!policy.accepts(score: 0.9, completed: 100.401, due: 100))
    }
    @Test func repairsTheMissingReleaseEvenWhenTheContactWasDetected() {
        let policy = ContactRecheckPolicy()
        let observed: [ContactFrameWindow.Stamp] = [.init(index: 0, timestampMs: 0), .init(index: 6, timestampMs: 200)]
        let missing = (1...5).map { ContactFrameWindow.Stamp(index: $0, timestampMs: $0*33) }
        #expect(policy.neighbor(contactMs: 0, missing: missing, observed: observed) == 2)
        #expect(policy.neighbor(contactMs: 0, missing: missing, observed: [observed[0]]) == nil)
        #expect(policy.neighbor(contactMs: 0, missing: missing, observed: observed+[.init(index: 1, timestampMs: 33)]) == nil)
        #expect(policy.neighbor(contactMs: 0, missing: missing, observed: [.init(index: 0, timestampMs: 0), .init(index: 9, timestampMs: 300)]) == nil)
    }
    @Test func aFourExposureImpactGapCanBeMeasuredWithoutExtendingTheDeadline() {
        let policy = ContactRecheckPolicy()
        // Original 22.31s foot contact: the last tracked ball preceded it by
        // 133ms; the next independently observed ball arrived 34ms afterward.
        #expect(policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.473, now: 100.4, due: 100, lastSource: 21.8, lastWall: 99.5))
        #expect(!policy.permits(source: 22.306, before: 22.139, after: 22.340,
            arrived: 22.473, now: 100.4, due: 100, lastSource: 21.8, lastWall: 99.5))
        #expect(!policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.473, now: 100.751, due: 100, lastSource: 21.8, lastWall: 99.5))
        #expect(!policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.473, now: 100.4, due: 100, lastSource: 22.2, lastWall: 100.3))
        #expect(!policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.32, now: 100.4, due: 100, lastSource: 21.8, lastWall: 99.5))
    }
}
