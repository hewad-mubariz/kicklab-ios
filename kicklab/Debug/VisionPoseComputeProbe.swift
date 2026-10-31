#if DEBUG
import CoreML
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Explicit diagnostic assignments only. Supported devices are not evidence of
/// the device Vision uses in automatic mode; a nil assignment remains automatic.
nonisolated enum VisionPoseComputeProbe {
    static func kind(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .neuralEngine: return "neuralEngine"
        @unknown default: return "unknown"
        }
    }
    static func supported<R: VisionRequest>(_ request: R) -> [ComputeStage: [MLComputeDevice]] {
        request.supportedComputeStageDevices
    }
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--vision-pose-compute"), args.indices.contains(index+1) else { return nil }
        return args[index+1]
    }
    static func warmupPixels() throws -> CVPixelBuffer? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--pose-warmup-image"), args.indices.contains(index+1) else { return nil }
        let path = args[index+1], parts = path.split(separator: "/")
        guard parts.count == 2, parts[0].hasPrefix("RFValidation-"), parts[1].hasSuffix(".png"),
              !parts.contains("..") else { throw NSError(domain: "InvalidPoseWarmupImage", code: 1) }
        return try VisionIntegrationProbe.pixels(URL.documentsDirectory.appendingPathComponent(path), edge: 512,
            context: CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false]))
    }
    static func configure(_ request: inout DetectHumanBodyPoseRequest, device: String?) throws {
        guard let device, device != "automatic" else { return }
        guard let selected = supported(request)[.main]?.first(where: { kind($0) == device }) else {
            throw NSError(domain: "Unsupported revision2 main compute device: \(device)", code: 1)
        }
        request.setComputeDevice(selected, for: .main)
    }
    static func configure(_ request: VNDetectHumanBodyPoseRequest, device: String?) throws {
        guard let device, device != "automatic" else { return }
        guard let selected = try request.supportedComputeStageDevices[.main]?.first(where: { kind($0) == device }) else {
            throw NSError(domain: "Unsupported legacy main compute device: \(device)", code: 1)
        }
        request.setComputeDevice(selected, for: .main)
    }
    static func metadata<R: VisionRequest>(_ request: R) -> [[String: Any]] {
        supported(request).map { stage, devices in
            ["stage": String(describing: stage), "supported": devices.map(kind),
             "assigned": request.computeDevice(for: stage).map(kind) ?? "automatic-unspecified"]
        }.sorted { String(describing: $0["stage"]) < String(describing: $1["stage"]) }
    }
    static func metadata(_ request: VNDetectHumanBodyPoseRequest) throws -> [[String: Any]] {
        try request.supportedComputeStageDevices.map { stage, devices in
            ["stage": stage.rawValue, "supported": devices.map(kind),
             "assigned": request.computeDevice(for: stage).map(kind) ?? "automatic-unspecified"]
        }.sorted { String(describing: $0["stage"]) < String(describing: $1["stage"]) }
    }
    private struct Arm {
        let name: String
        let legacy: VNDetectHumanBodyPoseRequest?
        let modern: DetectHumanBodyPoseRequest?
    }
    static func run(folder: URL) async throws -> [String: Any] {
        let plan = try JSONDecoder().decode(VisionIntegrationProbe.Plan.self,
            from: Data(contentsOf: folder.appendingPathComponent("probe.json")))
        guard !plan.images.isEmpty, plan.images.count <= 40, (1...5).contains(plan.repeats),
              plan.longEdges == [512],
              plan.images.allSatisfy({ $0 == URL(fileURLWithPath: $0).lastPathComponent })
        else { throw NSError(domain: "InvalidComputeProbe", code: 1) }
        let old = VNDetectHumanBodyPoseRequest(); old.revision = VNDetectHumanBodyPoseRequestRevision1
        var modern = DetectHumanBodyPoseRequest(.revision2); modern.detectsHands = false
        var arms = [Arm(name: "legacy-automatic", legacy: old, modern: nil),
                    Arm(name: "revision2-automatic", legacy: nil, modern: modern)]
        var descriptions: [String: Any] = ["legacy-automatic": try metadata(old),
            "revision2-automatic": metadata(modern)]
        for device in try old.supportedComputeStageDevices[.main] ?? [] {
            let r = VNDetectHumanBodyPoseRequest(); r.revision = VNDetectHumanBodyPoseRequestRevision1
            r.setComputeDevice(device, for: .main)
            let name = "legacy-"+kind(device)
            arms.append(Arm(name: name, legacy: r, modern: nil)); descriptions[name] = try metadata(r)
        }
        for device in supported(modern)[.main] ?? [] {
            var r = DetectHumanBodyPoseRequest(.revision2); r.detectsHands = false
            r.setComputeDevice(device, for: .main)
            let name = "revision2-"+kind(device)
            arms.append(Arm(name: name, legacy: nil, modern: r)); descriptions[name] = metadata(r)
        }
        let info: [String: Any] = ["hardware": RFDeviceProfile.hardwareIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "arms": descriptions, "assignmentNote": "Only main is explicitly selected; other stages use defaults. Automatic assignment does not identify actual hardware execution."]
        try RFDiagnosticJSON.data(info).write(to: folder.appendingPathComponent("compute-devices.json"), options: .atomic)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        let warm = try VisionIntegrationProbe.pixels(folder.appendingPathComponent(plan.images[0]), edge: 512, context: context)
        var rows = [[String: Any]](), failures = [[String: Any]](), active = [Arm]()
        func perform(_ arm: Arm, _ pixels: CVPixelBuffer) async throws -> [BodyPose] {
            if let request = arm.legacy { return try VisionIntegrationProbe.oldPoses(pixels, request: request) }
            return try await arm.modern!.perform(on: pixels, orientation: .up).prefix(8).map(VisionBodyPoseRevision2.convert)
        }
        for arm in arms {
            do {
                for _ in 0..<2 { _ = try await perform(arm, warm) }
                active.append(arm)
            } catch { failures.append(["arm": arm.name, "stage": "warmup", "error": String(describing: error)]) }
        }
        guard !active.isEmpty else { throw NSError(domain: "NoComputeProbeArm", code: 1) }
        for repetition in 0..<plan.repeats {
            for (index, image) in plan.images.enumerated() {
                let pixels = try VisionIntegrationProbe.pixels(folder.appendingPathComponent(image), edge: 512, context: context)
                let shift = (index+repetition)%active.count
                for arm in Array(active[shift...])+Array(active[..<shift]) {
                    let start = ProcessInfo.processInfo.systemUptime
                    do {
                        let poses = try await perform(arm, pixels)
                        let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
                        rows.append(["arm": arm.name, "image": image, "repeat": repetition+1,
                            "milliseconds": elapsed, "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                            "poses": VisionIntegrationProbe.encoded(poses)])
                    } catch { failures.append(["arm": arm.name, "image": image, "error": String(describing: error)]) }
                    try RFDiagnosticJSON.data(["rows": rows]).write(to: folder.appendingPathComponent("compute-results.json"), options: .atomic)
                    try RFDiagnosticJSON.data(["failures": failures]).write(to: folder.appendingPathComponent("compute-failures.json"), options: .atomic)
                    if ProcessInfo.processInfo.thermalState.rawValue > 1 { throw NSError(domain: "ComputeProbeThermal", code: 1) }
                }
            }
        }
        return ["mode": "pose-compute-probe", "rows": rows.count, "failures": failures,
            "activeArms": active.map(\.name), "hardware": RFDeviceProfile.hardwareIdentifier,
            "scope": "Nine fixed contact images; 512 long edge; two warmups; rotated arm order; request plus equal conversion; no concurrent ball model."]
    }
}
#endif
