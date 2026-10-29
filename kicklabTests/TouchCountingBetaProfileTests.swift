import Foundation
import Testing
@testable import kicklab

struct TouchCountingBetaProfileTests {
    private final class Resources {}

    /// This fixture was captured on iPhone 17 during the validated debug runs,
    /// before the Release profile existed. Compare actual factory output and
    /// pipeline identity, not just the intended list of enabled switches.
    @Test func releaseBetaMatchesMeasuredDeviceBaseline() throws {
        #if TOUCH_COUNTER_BETA
        #expect(TouchCountingBetaProfile.enabledForBuild)
        #expect(!TouchCountingDebugProfile.enabledForBuild)
        let url = try #require(Bundle(for: Resources.self).url(
            forResource: "testflight-counter-baseline-20261029", withExtension: "json"))
        let reference = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let args = TouchCountingDebugProfile.arguments
        let harness: Set<String> = ["--session-design", "--rf-full-app-review", "--touch-debug-hold"]
        let measured = try #require(reference["effectiveFlags"] as? [String])
        #expect(Set(args) == Set(measured).subtracting(harness))
        let policy = CountingPolicy.current
        #expect(policy.body.rawValue == reference["bodyPolicy"] as? String)
        #expect(policy.handling.rawValue == reference["handlingPolicy"] as? String)
        #expect(policy.verifiesContacts && policy.ground == .corroboratedFeet)
        let config = try #require(ContactCounterFactory.make(verifier: nil).traceSnapshot()?.config)
        let actual = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? NSDictionary)
        let expected = try #require(reference["counterConfig"] as? NSDictionary)
        #expect(actual == expected)
        #expect(TouchCountingDebugProfile.traceLimit == reference["traceLimit"] as? Int)
        let defaults = try #require(UserDefaults(suiteName: "TouchCountingBetaProfileTests"))
        defaults.removePersistentDomain(forName: "TouchCountingBetaProfileTests")
        defer { defaults.removePersistentDomain(forName: "TouchCountingBetaProfileTests") }
        let options = SessionAnalysisStore.pipelineOptions(arguments: args, defaults: defaults, resolution: .detailed)
        // Model tier is explicit; contact recheck tier follows this simulator's
        // hardware policy, so remove its compact marker for the iPhone17 reference.
        #expect(options.replacingOccurrences(of: RFContactRecheckTier.compactSignature, with: "")
            == reference["pipelineOptions"] as? String)
        #expect(ContactRecheckPolicy.usesSpannedWindow())
        #expect(ContactRecheckPolicy.usesEarlyRelease())
        #expect(ContactRecheckPolicy.usesBalancedMissingImpact())
        #expect(ContactSchedulingPolicy.enabled() && RFWorkerAdmissionPolicy.enabled())
        #expect(!ImpactGapRecoveryPolicy.chargesAcceptedRetriesOnly())
        #expect(!args.contains("--follow-vision-revision2"))
        #expect(RFContactRecheckTier.select(resolution: .compact, arguments: args) == .compact)
        #expect(RFContactRecheckTier.select(resolution: .detailed, arguments: args) == .full)
        #else
        #expect(!TouchCountingBetaProfile.enabledForBuild)
        #endif
    }
}
