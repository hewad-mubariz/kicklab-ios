import Foundation

/// Local Debug installs only until the phone accuracy/latency comparison is reviewed.
nonisolated enum ShoeRecoveryPolicy {
    static let preferenceKey = "juggledude.preview.shoe-recovery"
    static var available: Bool {
        #if DEBUG
        return ["com.juggledude", "com.juggledude.release120.preview"].contains(Bundle.main.bundleIdentifier ?? "")
        #else
        return false
        #endif
    }
    static var enabled: Bool {
        guard available else { return false }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--shoe-recovery-off") { return false }
        if args.contains("--shoe-recovery-on") { return true }
        return UserDefaults.standard.object(forKey: preferenceKey) == nil
            || UserDefaults.standard.bool(forKey: preferenceKey)
    }
    static var signature: String {
        enabled ? "|shoe-recovery-preview-v1|mp-full-4eaa5eb7|visible-foot-v2|pose-r2-foreground-cpu-fallback" : ""
    }
}
