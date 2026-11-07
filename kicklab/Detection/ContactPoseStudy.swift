import Foundation

/// Opt-in experiment only. The shipping pose policy remains unchanged.
nonisolated enum ContactPoseStudy {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("--pose-profile")
        || ProcessInfo.processInfo.arguments.contains("--pose-accelerated-study")
    static let accelerationEnabled = ProcessInfo.processInfo.arguments.contains("--pose-accelerated-study")
    #else
    static let enabled = false
    static let accelerationEnabled = false
    #endif

    static func canAccelerate(enabled: Bool = accelerationEnabled, lease: VideoWorkLease? = VideoWorkExecution.lease) -> Bool {
        // An inactive/expired job always uses the explicitly configured CPU
        // request, even if iOS still lets the worker finish a pending frame.
        enabled && lease?.isForeground == true && lease?.isCancelled == false
    }
}
