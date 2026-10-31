import Testing
@testable import kicklab

struct VisionRevisionExperimentTests {
    @Test func revisionsAreIndependentAndNormalCacheIdentityIsPreserved() {
        #expect(VisionRevisionExperiment.signature(arguments: []) == "")
        #expect(!VisionRevisionExperiment.bodyPose2(arguments: []))
        #expect(VisionRevisionExperiment.trackingRevision(arguments: []) == 1)
        #if DEBUG
        let pose = ["--vision-body-pose-revision2"]
        let track = ["--follow-vision-revision2"]
        #expect(VisionRevisionExperiment.bodyPose2(arguments: pose))
        #expect(VisionRevisionExperiment.trackingRevision(arguments: pose) == 1)
        #expect(!VisionRevisionExperiment.bodyPose2(arguments: track))
        #expect(VisionRevisionExperiment.trackingRevision(arguments: track) == 2)
        #expect(VisionRevisionExperiment.signature(arguments: pose) == "|vision-body-pose-swift-r2")
        #expect(VisionRevisionExperiment.signature(arguments: track) == "|vision-track-r2")
        #else
        #expect(VisionRevisionExperiment.signature(arguments: ["--vision-body-pose-revision2", "--follow-vision-revision2"]) == "")
        #endif
    }
    #if DEBUG
    @Test func modernAdapterKeepsLegacyCoordinatesConfidenceAndEvidence() {
        var pose = BodyPose()
        VisionBodyPoseRevision2.append(.leftAnkle, x: 0.25, visionY: 0.125, confidence: 0.8, to: &pose)
        #expect(pose.joints[.leftAnkle] == .init(x: 0.25, y: 0.875))
        #expect(pose.ankles[.left] == PoseLandmark(x: 0.25, y: 0.875, confidence: 0.8))
        VisionBodyPoseRevision2.append(.rightWrist, x: 0.5, visionY: 0.75, confidence: 0.2, to: &pose)
        #expect(pose.joints[.rightWrist] == nil)
        #expect(pose.wrists[.right] == PoseLandmark(x: 0.5, y: 0.25, confidence: 0.2))
        #expect(pose.landmarks[.rightWrist] == pose.wrists[.right])
        VisionBodyPoseRevision2.append(.leftHip, x: 0.375, visionY: 0.5, confidence: 0.3, to: &pose)
        #expect(pose.joints[.leftHip] != nil)
        #expect(pose.hips[.left]?.confidence == 0.3)
    }
    #endif
}
