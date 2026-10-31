#if DEBUG
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Explicit fixed-image diagnostic. It never feeds the counter or changes defaults.
nonisolated enum VisionIntegrationProbe {
    struct Plan: Decodable { let images: [String]; let longEdges: [Int]; let repeats: Int }
    static let names: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.nose,.nose),(.leftShoulder,.leftShoulder),(.rightShoulder,.rightShoulder),
        (.leftElbow,.leftElbow),(.rightElbow,.rightElbow),(.leftWrist,.leftWrist),(.rightWrist,.rightWrist),
        (.leftHip,.leftHip),(.rightHip,.rightHip),(.leftKnee,.leftKnee),(.rightKnee,.rightKnee),
        (.leftAnkle,.leftAnkle),(.rightAnkle,.rightAnkle)]

    static func oldPoses(_ pixels: CVPixelBuffer, request: VNDetectHumanBodyPoseRequest) throws -> [BodyPose] {
        try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        return try (request.results ?? []).prefix(8).map { observation in
            let points = try observation.recognizedPoints(.all)
            var pose = BodyPose()
            for (name, joint) in names {
                if let p = points[joint] {
                    VisionBodyPoseRevision2.append(name, x: p.location.x, visionY: p.location.y,
                        confidence: Double(p.confidence), to: &pose)
                }
            }
            return pose
        }
    }
    static func pixels(_ url: URL, edge: Int, context: CIContext) throws -> CVPixelBuffer {
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw NSError(domain: "PoseProbeImage", code: 1)
        }
        image = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, Double(edge)/max(image.extent.width,image.extent.height))
        image = image.transformed(by: .init(scaleX: scale, y: scale))
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer) == kCVReturnSuccess, let buffer else { throw NSError(domain: "PoseProbeBuffer", code: 1) }
        context.render(image, to: buffer)
        return buffer
    }
    static func encoded(_ poses: [BodyPose]) -> [[[String: Any]]] {
        poses.map { p in p.landmarks.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            ["joint": $0.key.rawValue, "x": $0.value.x, "y": $0.value.y, "confidence": $0.value.confidence]
        } }
    }
    static func run(folder: URL) async throws -> [String: Any] {
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: folder.appendingPathComponent("probe.json")))
        guard !plan.images.isEmpty, plan.images.count <= 40, (1...5).contains(plan.repeats),
            plan.longEdges.allSatisfy({ [512,768,1024].contains($0) }),
            plan.images.allSatisfy({ $0 == URL(fileURLWithPath: $0).lastPathComponent })
        else { throw NSError(domain: "InvalidPoseProbe", code: 1) }
        let old = VNDetectHumanBodyPoseRequest(); old.revision = VNDetectHumanBodyPoseRequestRevision1
        let bridge = VisionBodyPoseRevision2.Session()
        var native = DetectHumanBodyPoseRequest(.revision2); native.detectsHands = false
        var hands = DetectHumanBodyPoseRequest(.revision2); hands.detectsHands = true
        let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        let arms = ["legacy", "revision2_bridge", "revision2_native", "revision2_hands"]
        var rows = [[String: Any]](), worstThermal = ProcessInfo.processInfo.thermalState.rawValue
        let output = folder.appendingPathComponent("probe-results.json")
        for edge in plan.longEdges {
            let warm = try pixels(folder.appendingPathComponent(plan.images[0]), edge: edge, context: context)
            for _ in 0..<2 {
                _ = try oldPoses(warm, request: old)
                _ = try VisionBodyPoseRevision2.poses(in: warm, session: bridge)
                _ = try await native.perform(on: warm, orientation: .up)
                _ = try await hands.perform(on: warm, orientation: .up)
            }
            for repeatIndex in 0..<plan.repeats {
                for (index, name) in plan.images.enumerated() {
                    let image = try pixels(folder.appendingPathComponent(name), edge: edge, context: context)
                    let shift = (index+repeatIndex)%arms.count
                    for arm in Array(arms[shift...])+Array(arms[..<shift]) {
                        let start = ProcessInfo.processInfo.systemUptime
                        let poses: [BodyPose]; var handCount = 0
                        switch arm {
                        case "legacy": poses = try oldPoses(image, request: old)
                        case "revision2_bridge": poses = try VisionBodyPoseRevision2.poses(in: image, session: bridge)
                        case "revision2_native":
                            poses = try await native.perform(on: image, orientation: .up).prefix(8).map(VisionBodyPoseRevision2.convert)
                        default:
                            let result = try await hands.perform(on: image, orientation: .up)
                            handCount = result.reduce(0) { $0 + ($1.leftHand == nil ? 0 : 1) + ($1.rightHand == nil ? 0 : 1) }
                            poses = result.prefix(8).map(VisionBodyPoseRevision2.convert)
                        }
                        let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
                        let thermal = ProcessInfo.processInfo.thermalState.rawValue
                        worstThermal = max(worstThermal,thermal)
                        rows.append(["image": name, "longEdge": edge, "repeat": repeatIndex+1,
                            "arm": arm, "milliseconds": elapsed, "thermal": thermal,
                            "poses": encoded(poses), "hands": handCount])
                        if thermal > 1 { throw NSError(domain: "PoseProbeThermal", code: thermal) }
                    }
                }
                try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: output, options: .atomic)
            }
        }
        return ["mode": "pose-integration-probe", "rows": rows.count, "worstThermal": worstThermal,
            "scope": "Fixed upright images; rotated arm order; two warmups per size; timings include request and equal joint conversion, exclude decode/resize/JSON. No ball inference or counter workload.",
            "computeSelection": "Automatic defaults in all arms; no forced CPU/GPU/ANE selection."]
    }
}
#endif
