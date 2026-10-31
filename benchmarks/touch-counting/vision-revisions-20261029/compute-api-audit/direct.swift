import Vision
import CoreML
@available(iOS 18.0, *)
func inspectDirect() {
    let r = DetectHumanBodyPoseRequest(.revision2)
    _ = r.supportedComputeStageDevices
}
