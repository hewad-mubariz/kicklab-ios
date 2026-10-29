import Testing
@testable import kicklab

struct TouchCountingDebugProfileTests {
    @Test func normalDebugLaunchSelectsTheCompleteFieldTestProfile() {
        let args=TouchCountingDebugProfile.resolve(["Touch Counting Debug"],usesDebugDefaults:true)
        #expect(CountingPolicy.configured(arguments:args).body == .smallArcV23)
        #expect(CountingPolicy.configured(arguments:args).verifiesContacts)
        #expect(CountingPolicy.configured(arguments:args).handling == .temporalGripV2)
        #expect(Set(TouchCountingDebugProfile.flags).isSubset(of:Set(args)))
        #expect(RFWorkerAdmissionPolicy.enabled(arguments:args))
        #expect(AdjacentFootEvidencePolicy.enabled(arguments:args))
        #expect(ContactRecheckPolicy.usesLateApproach(arguments:args))
        #expect(GroundImpactEvidencePolicy.enabled(arguments:args))
        #expect(UnliftedFloorReboundPolicy.enabled(arguments:args))
        #expect(ObservedContactRecoveryPolicy.alignedLeg(arguments:args))
        #expect(ObservedContactRecoveryPolicy.terminalRebound(arguments:args))
        #expect(ObservedContactRecoveryPolicy.gapRebound(arguments:args))
        #expect(MeasuredReboundPolicy.slowRise(arguments:args))
        #expect(MeasuredReboundPolicy.raisedFoot(arguments:args))
        #expect(AlignedFootRegionPolicy.enabled(arguments:args))
        #expect(MeasuredFootImpactPolicy.toeLift(arguments:args))
        #expect(MeasuredFootImpactPolicy.floorRebound(arguments:args))
        #expect(MeasuredFootImpactPolicy.weakSupport(arguments:args))
    }
    @Test func productionAndExplicitComparisonsKeepTheirOwnConfiguration() {
        #expect(TouchCountingDebugProfile.resolve([],usesDebugDefaults:false).isEmpty)
        #expect(CountingPolicy.configured(arguments:[]).body == .visibleFootV21)
        for flag in ["--visible-foot-v21", "--small-arc-v23", "--touch-counter-manual-options"] {
            let input=["app",flag]
            #expect(TouchCountingDebugProfile.resolve(input,usesDebugDefaults:true)==input)
        }
    }
    @Test func resolvingTheProfileTwiceDoesNotAccumulateSwitches() {
        let first=TouchCountingDebugProfile.resolve(["app","--brief-toe-lift"],usesDebugDefaults:true)
        #expect(TouchCountingDebugProfile.resolve(first,usesDebugDefaults:true)==first)
        #expect(first.count == Set(first).count)
    }
}
