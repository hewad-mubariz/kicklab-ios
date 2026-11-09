import Foundation

/// Default contact recovery for the main app in local and release builds.
/// Debug field tests may disable only the auxiliary MediaPipe model. Existing
/// visible-foot recovery and the Vision revision remain identical in both runs.
nonisolated enum ShoeRecoveryPolicy {
    static let benchmarkPreferenceKey = "juggledude.benchmark.shoe-recovery"
    static var available: Bool {
        ["com.juggledude", "com.juggledude.release120.preview"].contains(Bundle.main.bundleIdentifier ?? "")
    }
    static var usesVisibleFootRecoveryV2: Bool { available }
    static var usesVisionRevision2: Bool { available }
    #if DEBUG
    static var launchOverride: Bool? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--shoe-recovery-off") { return false }
        if args.contains("--shoe-recovery-on") { return true }
        return nil
    }
    #endif
    static var enabled: Bool {
        guard available else { return false }
        #if DEBUG
        if let launchOverride { return launchOverride }
        if let benchmarkOverride = UserDefaults.standard.object(forKey: benchmarkPreferenceKey) as? Bool {
            return benchmarkOverride
        }
        #endif
        // Ignore the retired preview preference, including a previously saved Off.
        return true
    }
    static var signature: String { signature(enabled: enabled) }
    static func signature(enabled: Bool) -> String {
        guard available else { return "" }
        let model = enabled ? "|shoe-recovery-v1|mp-full-4eaa5eb7" : "|shoe-recovery-off"
        return model + "|visible-foot-v2|pose-r2-foreground-cpu-fallback"
    }
}
