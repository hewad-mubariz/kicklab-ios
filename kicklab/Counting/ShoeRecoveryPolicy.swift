import Foundation

/// Default contact recovery for the main app in local and release builds.
/// Debug benchmarks can compare the previous counter without exposing a setting.
nonisolated enum ShoeRecoveryPolicy {
    static let benchmarkPreferenceKey = "juggledude.benchmark.shoe-recovery"
    static var available: Bool {
        ["com.juggledude", "com.juggledude.release120.preview"].contains(Bundle.main.bundleIdentifier ?? "")
    }
    static var enabled: Bool {
        guard available else { return false }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--shoe-recovery-off") { return false }
        if args.contains("--shoe-recovery-on") { return true }
        if let benchmarkOverride = UserDefaults.standard.object(forKey: benchmarkPreferenceKey) as? Bool {
            return benchmarkOverride
        }
        #endif
        // Ignore the retired preview preference, including a previously saved Off.
        return true
    }
    static var signature: String {
        enabled ? "|shoe-recovery-v1|mp-full-4eaa5eb7|visible-foot-v2|pose-r2-foreground-cpu-fallback" : ""
    }
}
