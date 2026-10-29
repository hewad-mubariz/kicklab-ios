import Testing
@testable import kicklab

struct ContactRecheckPolicyTests {
    @Test func missingImpactPairKeepsAnApproachWhenOriginalReleaseAlreadyExists() {
        let missing = [64246,64280,64346,64379,64446,64480].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        let observed = [64213,64313,64413,64513].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        let control = ContactRecheckPolicy()
        var candidate = control
        candidate.balancesMissingImpact = true
        #expect(control.impactWindow(contactMs: 64379, missing: missing, observed: observed) == [64379,64346,64446])
        #expect(candidate.impactWindow(contactMs: 64379, missing: missing, observed: observed) == [64379,64346,64280])
        // Keep original scheduling when approach is already measured or a
        // close release is unavailable. Neither side can use a recheck as hint.
        let ready = observed + [.init(index: 64280, timestampMs: 64280)]
        #expect(candidate.impactWindow(contactMs: 64379, missing: missing.filter { $0.index != 64280 }, observed: ready)
            == control.impactWindow(contactMs: 64379, missing: missing.filter { $0.index != 64280 }, observed: ready))
        let noRelease = observed.filter { $0.timestampMs != 64413 }
        #expect(candidate.impactWindow(contactMs: 64379, missing: missing, observed: noRelease)
            == control.impactWindow(contactMs: 64379, missing: missing, observed: noRelease))
        #expect(candidate.maximumRetainedFrames == control.maximumRetainedFrames)
        #expect(candidate.maximumStartLatency == control.maximumStartLatency)
        #expect(!ContactRecheckPolicy.usesBalancedMissingImpact(arguments: []))
    }
    @Test func observedImpactUsesTheSameApproachBudgetAtTheOtherDetectionPhase() {
        let missing = [64280,64313,64379,64413,64480,64513].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        let observed = [64246,64346,64446,64546].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        var candidate = ContactRecheckPolicy()
        candidate.balancesMissingImpact = true
        #expect(candidate.impactWindow(contactMs: 64379, missing: missing, observed: observed) == [64379,64413,64280])
        let missingIdentity = observed.filter { $0.timestampMs != 64246 }
        #expect(!candidate.impactWindow(contactMs: 64379, missing: missing, observed: missingIdentity).contains(64280))
    }
    @Test func missingApproachDoesNotDisplaceTheReleaseOfAFloorRebound() {
        // Observed 50.68 s floor bounce: losing 50.713 s lets a later rising
        // ball view at 50.746 s masquerade as the contact near a planted foot.
        let missing = [50580,50613,50680,50713,50780].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        let observed = [50546,50646,50746,50846].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        var candidate = ContactRecheckPolicy()
        candidate.balancesMissingImpact = true
        #expect(candidate.impactWindow(contactMs: 50680, missing: missing, observed: observed) == [50680,50713,50580])
        let noRelease = missing.filter { $0.timestampMs != 50713 }
        #expect(candidate.impactWindow(contactMs: 50680, missing: noRelease, observed: observed)
            == ContactRecheckPolicy().impactWindow(contactMs: 50680, missing: noRelease, observed: observed))
    }
    @Test func busyWorkerDoesNotSpendTheNextReleaseRetry() {
        func run(_ acceptedOnly: Bool) -> [ImpactGapRetrySchedule.Outcome] {
            var schedule = ImpactGapRetrySchedule(chargesAcceptedOnly: acceptedOnly)
            return [(0.0, false), (0.033, true), (0.066, true), (0.334, true)].map { offset, idle in
                schedule.attempt(source: 10+offset, hintTime: 9.967+offset,
                    now: 110.21+offset, due: 110+offset, outstanding: 1, budget: 0.08,
                    submit: { idle })
            }
        }
        #expect(run(false) == [.workerBusy, .ineligible, .ineligible, .submitted])
        #expect(run(true) == [.workerBusy, .submitted, .ineligible, .submitted])
        #expect(!ImpactGapRecoveryPolicy.chargesAcceptedRetriesOnly(arguments: []))
    }

    @Test func admissionRetryKeepsRateAndBacklogLimitsAcrossLongBusyRuns() {
        var schedule = ImpactGapRetrySchedule(chargesAcceptedOnly: true)
        var admitted: [Double] = []
        for frame in 0..<300 {
            let time = Double(frame)/30
            let result = schedule.attempt(source: 10+time, hintTime: 9.967+time,
                now: 110.21+time, due: 110+time, outstanding: frame < 30 ? 5 : 1,
                budget: 0.08, submit: { frame % 3 == 2 })
            if case .submitted = result { admitted.append(time) }
        }
        #expect(!admitted.isEmpty)
        #expect(admitted.first! >= 1)
        #expect(zip(admitted, admitted.dropFirst()).allSatisfy { $1-$0 >= 0.3-1e-9 })
        #expect(admitted.count <= 30)
    }
    @Test func oldestContactImagesFinishBeforeTheirExistingDeadlines() {
        // Paced new120: the 60.413 s approach was third, reached the worker
        // at 725 ms age and expired while waiting. The first regular job has
        // 40 ms left; subsequent regular/contact jobs take about 78/77 ms.
        let stamps = [60413,60446,60480].map { ContactFrameWindow.Stamp(index:$0,timestampMs:$0) }
        let targets = [60480,60446,60413]
        let control = ContactRecheckPolicy()
        var candidate = control; candidate.schedulesContactEvidence = true
        func completed(_ order: [Int]) -> [Int] {
            var now = 60480.0 + 382
            var result: [Int] = []
            for (slot, source) in order.enumerated() {
                now += slot == 0 ? 40 : 78 // the already-admitted regular inference
                if now-Double(source) <= candidate.maximumStartLatency*1000 {
                    result.append(source); now += 77
                }
            }
            return result
        }
        let ages = Dictionary(uniqueKeysWithValues: targets.map { ($0, (60480.0+382-Double($0))/1000) })
        #expect(completed(control.executionOrder(targets, missing:stamps, ages:ages, inferenceBudget:0.080)).count == 2)
        #expect(completed(candidate.executionOrder(targets, missing:stamps, ages:ages, inferenceBudget:0.080)).sorted() == targets.sorted())
        #expect(candidate.executionOrder(targets, missing:stamps, ages:ages.mapValues { $0-0.2 }, inferenceBudget:0.080) == targets)
        #expect(candidate.executionOrder(targets, missing:stamps, ages:[:], inferenceBudget:0.080) == targets)
        #expect(candidate.maximumStartLatency == control.maximumStartLatency)
        #expect(candidate.maximumResultLatency == control.maximumResultLatency)
        #expect(!ContactSchedulingPolicy.enabled(arguments: []))
    }

    @Test func missingProposalKeepsAUsefulApproachWithinThreeRealImages() {
        // 79.428 s: original detections at 79.261 and 79.461 bracket an
        // occluded low kick. The -67 ms sample was too late for foot approach.
        let missing = [79328,79361,79395,79428].map { ContactFrameWindow.Stamp(index:$0,timestampMs:$0) }
        let observed = [79261,79461,79528].map { ContactFrameWindow.Stamp(index:$0,timestampMs:$0) }
        let control = ContactRecheckPolicy(extendsVisibleApproach:true, measuresLateApproach:true)
        var candidate = control; candidate.schedulesContactEvidence = true
        #expect(control.impactWindow(contactMs:79428,missing:missing,observed:observed) == [79428,79395,79361])
        let selected = candidate.impactWindow(contactMs:79428,missing:missing,observed:observed)
        #expect(Set(selected) == Set([79428,79395,79328]))
        let ages = Dictionary(uniqueKeysWithValues: selected.map { ($0, (79428.0+450-Double($0))/1000) })
        #expect(candidate.executionOrder(selected,missing:missing,ages:ages,inferenceBudget:0.080) == [79328,79395,79428])
        // Preserve existing selection when the independent release is absent,
        // too far away, or the approach already has a closer original image.
        for times in [[79261], [79261,79528], [79261,79328,79461,79528]] {
            let obs = times.map { ContactFrameWindow.Stamp(index:$0,timestampMs:$0) }
            let miss = missing.filter { !times.contains($0.timestampMs) }
            #expect(candidate.impactWindow(contactMs:79428,missing:miss,observed:obs)
                == control.impactWindow(contactMs:79428,missing:miss,observed:obs))
        }
    }

    @Test func visibleApproachCanRetainEightExposuresWithAnIndependentRecentRelease() {
        let old = ContactRecheckPolicy()
        let repaired = ContactRecheckPolicy(extendsVisibleApproach: true)
        let missing: [ContactFrameWindow.Stamp] = [.init(index: 975, timestampMs: 1000)]
        // 120 s outdoor recording at 32.548 s: the last original ball was
        // 266 ms earlier; the next original ball was 33 ms later. The impact
        // image itself is available in the source video, not interpolated.
        let observed: [ContactFrameWindow.Stamp] = [.init(index: 967, timestampMs: 734),
                                                   .init(index: 976, timestampMs: 1033)]
        #expect(old.impactWindow(contactMs: 1000, missing: missing, observed: observed).isEmpty)
        #expect(repaired.impactWindow(contactMs: 1000, missing: missing, observed: observed) == [975])
        #expect(repaired.impactWindow(contactMs: 1000, missing: missing, observed: [observed[0]]).isEmpty)
        #expect(repaired.impactWindow(contactMs: 1000, missing: missing,
            observed: [.init(index: 966,timestampMs: 732),observed[1]]).isEmpty)
        #expect(repaired.impactWindow(contactMs: 1000, missing: missing,
            observed: [observed[0],.init(index: 980,timestampMs: 1135)]).isEmpty)
        #expect(repaired.maximumRetainedFrames == old.maximumRetainedFrames)
        #expect(repaired.maximumRetainedAge == old.maximumRetainedAge)
    }

    @Test func longerApproachDoesNotExtendDeadlinesRateLimitsOrReleaseAge() {
        let policy = ContactRecheckPolicy(extendsVisibleApproach: true)
        func permits(before: Double = 0.733, after: Double = 1.033,
                     arrived: Double = 1.1, now: Double = 100.4, last: Double = 0.5) -> Bool {
            policy.permits(source: 1, before: before, after: after, arrived: arrived,
                now: now, due: 100, lastSource: last, lastWall: 99.5)
        }
        #expect(permits())
        #expect(!permits(before: 0.732))
        #expect(!permits(after: 1.135, arrived: 1.2))
        #expect(!permits(arrived: 1.501))
        #expect(!permits(now: 100.751))
        #expect(!permits(last: 0.701))
        #expect(!policy.acceptsResult(now: 100.951, due: 100))
        let missing = (-2...2).map { ContactFrameWindow.Stamp(index: 100+$0, timestampMs: 1000+$0*33) }
        #expect(policy.impactWindow(contactMs: 1000, missing: missing,
            observed: [.init(index: 90,timestampMs: 800),.init(index: 103,timestampMs: 1100)]).count == 3)
    }

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
    @Test func lateProposalUsesAnEarlierActualImageWithinTheSameBudget() {
        var policy = ContactRecheckPolicy(extendsVisibleApproach: true)
        let missing = [17016,17050,17083,17183,17216].map { ContactFrameWindow.Stamp(index:$0,timestampMs:$0) }
        let observed = [16916,17116,17150,17250].map { ContactFrameWindow.Stamp(index:$0,timestampMs:$0) }
        let old = policy.impactWindow(contactMs:17116,missing:missing,observed:observed)
        #expect(old == [17083,17050,17183])
        policy.measuresLateApproach=true
        #expect(policy.impactWindow(contactMs:17116,missing:missing,observed:observed) == [17083,17050,17016])
        // No original close release: preserve that side's measurement.
        #expect(policy.impactWindow(contactMs:17116,missing:missing,observed:observed.filter { $0.timestampMs != 17150 }) == old)
        // A shorter approach hole does not move the existing window.
        let dense = observed + [.init(index:17016,timestampMs:17016)]
        policy.measuresLateApproach=false
        let control=policy.impactWindow(contactMs:17116,missing:missing.filter { $0.timestampMs != 17016 },observed:dense)
        policy.measuresLateApproach=true
        #expect(policy.impactWindow(contactMs:17116,missing:missing.filter { $0.timestampMs != 17016 },observed:dense) == control)
        #expect(!ContactRecheckPolicy.usesLateApproach(arguments:[]))
    }

    @Test func earlyProposalMeasuresTheActualLaterImpactWithoutIncreasingBudget() {
        // Saved old-five 291.466 s proposal: the physical kick is near 291.566.
        let missing = [291366,291400,291500,291533,291566,291600].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        let observed = [291333,291433,291466,291633,291666].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        let control = ContactRecheckPolicy(extendsVisibleApproach: true, measuresLateApproach: true)
        var candidate = control
        candidate.measuresEarlyRelease = true
        #expect(control.impactWindow(contactMs:291466,missing:missing,observed:observed) == [291500,291400,291533])
        #expect(candidate.impactWindow(contactMs:291466,missing:missing,observed:observed) == [291500,291533,291566])
        #expect(candidate.maximumRetainedFrames == control.maximumRetainedFrames)
        #expect(candidate.maximumStartLatency == control.maximumStartLatency)
        #expect(candidate.maximumResultLatency == control.maximumResultLatency)
        #expect(!ContactRecheckPolicy.usesEarlyRelease(arguments: []))
    }

    @Test func earlyProposalKeepsApproachEvidenceWhenItIsNotRedundant() {
        let missing = [900,934,1034,1067,1100,1134].map {
            ContactFrameWindow.Stamp(index: $0, timestampMs: $0)
        }
        let control = ContactRecheckPolicy(extendsVisibleApproach: true, measuresLateApproach: true)
        var candidate = control
        candidate.measuresEarlyRelease = true
        for times in [[800,1000,1167], [967,1000,1134], [967,1167], [967,1000], [1000,1167]] {
            let observed = times.map { ContactFrameWindow.Stamp(index: $0, timestampMs: $0) }
            #expect(candidate.impactWindow(contactMs:1000,missing:missing,observed:observed)
                == control.impactWindow(contactMs:1000,missing:missing,observed:observed))
        }
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
