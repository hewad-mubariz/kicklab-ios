import Vision
import CoreML
@available(iOS 18.0, *)
func inspect<R: VisionRequest>(_ r: R) -> [ComputeStage: [MLComputeDevice]] {
    r.supportedComputeStageDevices
}
@available(iOS 18.0, *)
func inspectBody() {
    var r = DetectHumanBodyPoseRequest(.revision2)
    let devices = inspect(r)
    _ = r.computeDevice(for: .main)
    if let device = devices[.main]?.first {
        r.setComputeDevice(device, for: .main)
    }
}
