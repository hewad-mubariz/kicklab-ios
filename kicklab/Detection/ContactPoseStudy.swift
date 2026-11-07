import Foundation

/// Diagnostic profiling and an override for the otherwise CPU-pinned A/B arm.
/// Normal imports use ContactPoseComputePolicy without either launch flag.
nonisolated enum ContactPoseStudy {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("--pose-profile")
        || ProcessInfo.processInfo.arguments.contains("--pose-accelerated-study")
    static let accelerationEnabled = ProcessInfo.processInfo.arguments.contains("--pose-accelerated-study")
    #else
    static let enabled = false
    static let accelerationEnabled = false
    #endif
}
