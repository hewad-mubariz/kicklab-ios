import Foundation

/// Contact refinements that use the existing ball detector and lazy Apple Vision
/// observations. Counter V2 adds selective toe evidence when native foot proof fails.
nonisolated enum ContactRecoveryPolicy {
    static var available: Bool {
        ["com.juggledude", "com.juggledude.release120.preview"].contains(Bundle.main.bundleIdentifier ?? "")
    }
    static var usesVisibleFootRecoveryV2: Bool { available }
    static var usesVisionRevision2: Bool { available }
    static var signature: String {
        guard available else { return "" }
        // Version Counter V2 separately from the retired per-frame shoe model and
        // the former native-only counter; saved decisions remain historical.
        return "|shoe-recovery-off|visible-foot-v2|pose-r2-foreground-cpu-fallback" + CounterV2Policy.signature
    }
}
