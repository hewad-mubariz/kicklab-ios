import Testing
@testable import kicklab

struct ContactEvidenceSpanTests {
    @Test func anExistingWindowKeepsItsOriginalImagesEvenWhenEarlierImpactIsAvailable() {
        let control = ContactRecheckPolicy(extendsVisibleApproach: true)
        let span = ContactRecheckPolicy(extendsVisibleApproach: true, spansContactWindow: true)
        let missing = [25365,25398,25431,25465,25531].enumerated().map {
            ContactFrameWindow.Stamp(index: $0.offset, timestampMs: $0.element)
        }
        let observed = [25231,25498,25565].enumerated().map {
            ContactFrameWindow.Stamp(index: $0.offset+100, timestampMs: $0.element)
        }
        #expect(control.impactWindow(contactMs: 25465, missing: missing, observed: observed) == [3,2,4])
        #expect(span.impactWindow(contactMs: 25465, missing: missing, observed: observed) == [3,2,4])
    }
    @Test func earlyReversalCanMeasureAnEligibleReleaseBeyondSixtySevenMilliseconds() {
        let control = ContactRecheckPolicy(extendsVisibleApproach: true)
        let span = ContactRecheckPolicy(extendsVisibleApproach: true, spansContactWindow: true)
        let missing = [36998,37031,37065,37098,37131,37165].enumerated().map {
            ContactFrameWindow.Stamp(index: $0.offset, timestampMs: $0.element)
        }
        let observed: [ContactFrameWindow.Stamp] = [.init(index: 100, timestampMs: 36965),
                                                   .init(index: 101, timestampMs: 37198)]
        #expect(control.impactWindow(contactMs: 36965, missing: missing, observed: observed).isEmpty)
        #expect(span.impactWindow(contactMs: 36965, missing: missing, observed: observed) == [2,3])
    }
    @Test func spanStillRequiresOriginalIdentityOnBothSidesAndCapsTheBudget() {
        let span = ContactRecheckPolicy(extendsVisibleApproach: true, spansContactWindow: true)
        let missing = (-5...5).map { ContactFrameWindow.Stamp(index: $0+10, timestampMs: 1000+$0*33) }
        let before = ContactFrameWindow.Stamp(index: 100, timestampMs: 800)
        let after = ContactFrameWindow.Stamp(index: 101, timestampMs: 1100)
        let selected = span.impactWindow(contactMs: 1000, missing: missing, observed: [before,after])
        #expect(selected.count <= 3)
        #expect(selected.allSatisfy { id in
            let time = missing.first { $0.index == id }!.timestampMs
            return abs(time-1000) <= 134 && time-before.timestampMs <= 267 && after.timestampMs-time <= 134
        })
        #expect(span.impactWindow(contactMs: 1000, missing: missing, observed: [before]).isEmpty)
        #expect(span.impactWindow(contactMs: 1000, missing: missing, observed: [after]).isEmpty)
        #expect(span.maximumRetainedFrames == 8)
        #expect(span.maximumResultLatency == 0.950)
        #expect(!ContactRecheckPolicy.usesSpannedWindow(arguments: []))
        #expect(ContactRecheckPolicy.usesSpannedWindow(arguments: ["--contact-evidence-span"]))
    }

    @Test func continuousReleaseDoesNotRepairAnUnrelatedApproachHoleAtReviewedFloorBounce() {
        let span = ContactRecheckPolicy(extendsVisibleApproach: true, spansContactWindow: true,
                                       measuresLateApproach: true, measuresEarlyRelease: true)
        let missing = [ContactFrameWindow.Stamp(index: 2686, timestampMs: 89595)]
        let observed = [89561,89628,89661,89695,89728,89761,89795].enumerated().map {
            ContactFrameWindow.Stamp(index: $0.offset+3000, timestampMs: $0.element)
        }
        #expect(span.impactWindow(contactMs: 89695, missing: missing, observed: observed).isEmpty)
    }

    @Test func delayedOriginalReleaseStillAllowsTheMeasuredEarlyImpactImages() {
        let span = ContactRecheckPolicy(extendsVisibleApproach: true, spansContactWindow: true)
        let missing = [119191,119225,119258,119291,119325,119358].enumerated().map {
            ContactFrameWindow.Stamp(index: $0.offset, timestampMs: $0.element)
        }
        let observed = [119125,119158,119391].enumerated().map {
            ContactFrameWindow.Stamp(index: $0.offset+100, timestampMs: $0.element)
        }
        #expect(span.impactWindow(contactMs: 119158, missing: missing, observed: observed) == [2,3])
        #expect(span.impactWindow(contactMs: 119158, missing: missing,
                                 observed: observed.filter { $0.timestampMs != 119158 }).isEmpty)
    }
}
