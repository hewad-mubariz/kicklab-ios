import Foundation

/// Debug-only integration experiment: a second measured pose on the SAME
/// image, only when revision2 returned no body and a player is already selected.
/// Existing person matching, caches and all contact vetoes remain authoritative.
nonisolated enum PoseEmptyFallbackPolicy {
    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        arguments.contains("--pose-empty-legacy-fallback-v1")
        #else
        false
        #endif
    }
    static func permits(enabled: Bool, revision2: Bool, rawPoseCount: Int,
                        player: ActivePlayerSelection?) -> Bool {
        enabled && revision2 && rawPoseCount == 0 && player?.canMatchPose == true
    }
}
