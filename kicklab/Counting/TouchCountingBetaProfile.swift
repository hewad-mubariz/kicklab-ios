import Foundation

/// Fixed TestFlight baseline measured on both phone tiers on 29 October.
/// Selected explicitly by TouchCounterBeta.xcconfig. No recording-specific
/// exceptions, command-line overrides, retry-admission or Vision revision 2.
nonisolated enum TouchCountingBetaProfile {
    static let identifier = "outdoor-balanced-v3-20261029"
    static var enabledForBuild: Bool {
        #if TOUCH_COUNTER_BETA
        true
        #else
        false
        #endif
    }
    static let flags = [
        "--weak-low-foot-proof",
        "--balanced-missing-impact",
        "--settled-rebound-probe",
        "--raised-forefoot-proof",
        "--measured-rebound-confirmation",
        "--early-impact-evidence",
        "--contact-evidence-span",
        "--contact-evidence-scheduling",
        "--corroborated-floor-rebound",
        "--small-arc-v23",
        "--rf-interleave-contact",
        "--adjacent-foot-evidence",
        "--slow-measured-rise",
        "--raised-compact-foot",
        "--late-impact-evidence",
        "--ground-impact-evidence",
        "--aligned-leg-ground",
        "--terminal-rebound-evidence",
        "--measured-gap-candidate",
        "--unlifted-floor-rebound",
        "--aligned-foot-region",
        "--brief-toe-lift",
        "--descending-floor-rebound",
        "--corroborated-support-ankle",
    ]
}
