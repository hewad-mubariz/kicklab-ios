import Foundation

/// The dedicated field-test app must use the same configuration after a normal
/// icon launch as during a Mac-assisted test. Other builds retain their defaults.
nonisolated enum TouchCountingDebugProfile {
    static let identifier = "outdoor-v23-20261028"
    static let flags = [
        "--small-arc-v23", "--rf-interleave-contact", "--adjacent-foot-evidence",
        "--slow-measured-rise", "--raised-compact-foot", "--late-impact-evidence",
        "--ground-impact-evidence", "--aligned-leg-ground", "--terminal-rebound-evidence",
        "--measured-gap-candidate", "--unlifted-floor-rebound", "--aligned-foot-region",
        "--brief-toe-lift", "--descending-floor-rebound", "--corroborated-support-ankle"
    ]
    static var enabledForBuild: Bool {
        #if DEBUG && TOUCH_COUNTING_DEBUG
        true
        #else
        false
        #endif
    }
    static var arguments: [String] {
        TouchCountingBetaProfile.enabledForBuild
            ? TouchCountingBetaProfile.flags : resolve(ProcessInfo.processInfo.arguments)
    }
    // The guided field tests include 15-minute recordings at 30 analysis FPS.
    // Keep the same bounded 20-minute numeric journal in the field-test beta.
    static var traceLimit: Int { (enabledForBuild || TouchCountingBetaProfile.enabledForBuild) ? 36_100 : 18_000 }

    /// Explicit historical policy launches and manual A/B tests keep exactly
    /// their requested options. Pure configured(arguments:) APIs stay explicit.
    static func resolve(_ arguments: [String], usesDebugDefaults: Bool = enabledForBuild) -> [String] {
        let policyFlags: Set<String> = ["--small-arc-v23", "--measured-foot-v22", "--visible-foot-v21",
            "--toe-contact-v20", "--floor-rescue-v19", "--floor-evidence-v18", "--impact-window-v17",
            "--contact-evidence-v16", "--foot-evidence-v15"]
        guard usesDebugDefaults, !arguments.contains("--touch-counter-manual-options"),
              !arguments.contains(where: { policyFlags.contains($0) }) else { return arguments }
        return arguments + flags.filter { !arguments.contains($0) }
    }

    /// A normal launch leaves inspectable evidence of the actual compiled
    /// profile, effective switches and factory configuration, without recording.
    static func writeLaunchReport() {
        #if canImport(UIKit) && ((DEBUG && TOUCH_COUNTING_DEBUG) || TOUCH_COUNTER_BETA)
        do {
            let raw = ProcessInfo.processInfo.arguments
            let effective = arguments
            let policy = CountingPolicy.current
            let counter = ContactCounterFactory.make(verifier:nil)
            let config = try counter.traceSnapshot().map {
                try JSONSerialization.jsonObject(with:JSONEncoder().encode($0.config))
            }
            let report: [String:Any] = [
                "profile": TouchCountingBetaProfile.enabledForBuild ? TouchCountingBetaProfile.identifier : identifier,
                "testFlightBetaProfile": TouchCountingBetaProfile.enabledForBuild,
                "traceLimit": traceLimit,
                "build": Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",
                "automaticDebugDefaults": enabledForBuild && resolve(raw) != raw,
                "explicitLaunchFlags": raw.filter { $0.hasPrefix("--") },
                "effectiveFlags": effective.filter { $0.hasPrefix("--") },
                "bodyPolicy": policy.body.rawValue,
                "handChecks": policy.verifiesContacts,
                "handlingPolicy": policy.handling.rawValue,
                "counterConfig": config ?? NSNull(),
                "workerInterleaving": RFWorkerAdmissionPolicy.enabled(),
                "adjacentFootEvidence": AdjacentFootEvidencePolicy.enabled(),
                "lateImpactEvidence": ContactRecheckPolicy.usesLateApproach(),
                "groundImpactEvidence": GroundImpactEvidencePolicy.enabled(),
                "unliftedFloorRebound": UnliftedFloorReboundPolicy.enabled(),
                "alignedLegGround": ObservedContactRecoveryPolicy.alignedLeg(),
                "raisedCompactFoot": MeasuredReboundPolicy.raisedFoot(),
                "corroboratedSupportAnkle": MeasuredFootImpactPolicy.weakSupport(),
                "pipelineOptions": SessionAnalysisStore.pipelineOptions(arguments:effective,defaults:.standard)
            ]
            let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:URL.documentsDirectory.appendingPathComponent("touch-counter-profile.json"),options:.atomic)
        } catch { print("Touch counter profile report failed: \(error)") }
        #endif
    }
}
