import CoreML

/// The two exports share weights, RGB normalization and detection thresholds.
/// Precision is explicit so a study cannot fall through to the YOLO adapter or
/// enable Neural Engine execution, whose numerical drift is larger for this export.
nonisolated enum RFSmallModel: String, CaseIterable {
    case fp32 = "RFDETRSmallRecovery040FP32"
    case fp16 = "RFDETRSmallRecovery040FP16"

    var outputType: MLMultiArrayDataType { self == .fp16 ? .float16 : .float32 }
    var precision: String { self == .fp16 ? "FP16" : "FP32" }
    var displayName: String { displayName(resolution: RFDeviceProfile.current) }
    func displayName(resolution: RFInputResolution) -> String {
        "RF-DETR Small \(precision) · \(self == .fp16 ? resolution.rawValue : 384) · dev.8 · 0.40"
    }
    var pipelineIdentity: String { pipelineIdentity(resolution: RFDeviceProfile.current) }
    func pipelineIdentity(resolution: RFInputResolution) -> String {
        if self == .fp32 { return "rfseg-dev8-rgb384-fp32-gpu-v1" }
        // Graph and shared weight identities from the verified export manifest.
        return "rfshared-e0c3e470cdb8-c8c1b8d53923|function=\(resolution.functionName)|rgb\(resolution.rawValue)|fp16|cpuAndGPU-cpuFallback-v1"
    }
    var foregroundComputeUnits: MLComputeUnits { .cpuAndGPU }
}
