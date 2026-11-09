import Foundation

/// Contact refinements that use the existing ball detector and lazy Apple Vision
/// observations. No separately bundled pose model or runtime is required.
nonisolated enum ContactRecoveryPolicy {
    static var available: Bool {
        ["com.juggledude", "com.juggledude.release120.preview"].contains(Bundle.main.bundleIdentifier ?? "")
    }
    static var usesVisibleFootRecoveryV2: Bool { available }
    static var usesVisionRevision2: Bool { available }
    static var signature: String {
        guard available else { return "" }
        // Preserve the tested model-off identity. Saved model-on evidence cannot
        // match; retired launch flags and stored preferences have no effect.
        return "|shoe-recovery-off|visible-foot-v2|pose-r2-foreground-cpu-fallback"
    }
}
