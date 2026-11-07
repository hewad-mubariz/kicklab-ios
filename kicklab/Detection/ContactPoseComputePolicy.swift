import Foundation

/// Imported-video pose inference follows its job's lifecycle. Live-camera
/// workers have no video lease and retain their existing Vision configuration.
nonisolated enum ContactPoseComputePolicy {
    static let signature = "|video-pose-lifecycle-v1"

    static func followsVideoLifecycle(
        lease: VideoWorkLease? = VideoWorkExecution.lease,
        accuracyComparison: Bool = VideoWorkExecution.accuracyComparison,
        accelerationStudy: Bool = ContactPoseStudy.accelerationEnabled
    ) -> Bool {
        lease != nil && (!accuracyComparison || accelerationStudy)
    }

    static func canAccelerate(lease: VideoWorkLease? = VideoWorkExecution.lease) -> Bool {
        // Even a device that supports background GPU uses the validated CPU
        // pose path when inactive. Expiration must never admit new GPU work.
        lease?.isForeground == true && lease?.isCancelled == false
    }
}
