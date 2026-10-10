//
//  BallDetector.swift
//  kicklab
//
//  SSDLite returns ten decoded scalars. Faster R-CNN returns final boxes,
//  probabilities and class labels after NMS. YOLOX returns dense candidates;
//  The crop experiment uses class-wise NMS and causal candidate association.
//  We select the highest-scoring ball
//  and person using stride-aware MLMultiArray subscripts. Network box decoding,
//  softmax and NMS remain inside Core ML.
//
//  Everything returned is normalised 0-1. The counter's thresholds are fractions
//  of the frame; handing it pixels would not fail loudly, it would count wrongly.
//

import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO

nonisolated struct Detection {
    var score: Double
    /// Centre and size, normalised 0-1.
    var x, y, width, height: Double
}

nonisolated struct FrameDetections {
    var ball: Detection?
    var person: Detection?
    var ballMask: BallMask? = nil
    var usesBallMasks: Bool = false
}

/// Each camera queue or video-analysis worker owns its detector exclusively.
/// This mutable inference state is not shared between concurrent workers.
nonisolated final class BallDetector {
    /// Layout of the model's single output.
    private enum Slot {
        static let ballScore = 0, ballBox = 1
        static let personScore = 5, personBox = 6
        static let count = 10
    }

    /// The experimental model uses portrait input; SSDLite retains its 320 square.
    private let inputWidth: Int
    private let inputHeight: Int
    private let preservesAspect: Bool
    private let isYOLOX: Bool
    private let isYOLO26: Bool
    let marginalRetryEnabled: Bool
    private let marginalRetry = MarginalBallRetry()
    let directConfirmationEnabled: Bool
    private let directConfirmation = BallDetectionConfirmation()
    let guardedRecoveryEnabled: Bool
    private let guardedFollower = GuardedBallFollower()
    private let nativePixels = NativeBallPixelTrack()
    private(set) var lastFollowKind = "detector"
    private(set) var lastFollowCalls = 1
    private(set) var lastSceneCut = false
    private var guardedDimensions = CGSize.zero
    let hasMaskOutputs: Bool
    let modelName: String
    let activeBallThreshold: Double
    private let batchModelCompatible: Bool
    var supportsFrameBatching: Bool { batchModelCompatible && !roiEnabled && !guardedRecoveryEnabled }
    var supportsDistantVisualRecovery: Bool {
        batchModelCompatible && !roiEnabled && !guardedRecoveryEnabled && (marginalRetryEnabled || directConfirmationEnabled)
    }

    /// Opt-in until paired device timing and output checks qualify this path.
    nonisolated static func visualBatchSize(visualOnly: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) -> Int {
        visualOnly && (arguments.contains("--visual-batch2") || arguments.contains("--visual-async2")) && !arguments.contains("--visual-serial") ? 2 : 1
    }

    enum BatchError: Error, Equatable { case unsupported, invalidFrames, outputCount, wrongDetector, consumed, outOfOrder }
    fileprivate final class BatchCursor { var next = 0 }

    /// Own both the immutable tensor and source pixels through ordered decode.
    /// Camera inputProvider is reusable scratch and must never enter a batch.
    final class PreparedFrame {
        fileprivate let owner: ObjectIdentifier
        fileprivate let pixels: CVPixelBuffer
        fileprivate let time: Double
        fileprivate let input: MLFeatureProvider
        fileprivate let output: MLFeatureProvider
        fileprivate let content: CGRect
        fileprivate let preprocessMS, inferenceMS, preparationMS: Double
        fileprivate var consumed = false
        fileprivate let cursor: BatchCursor
        fileprivate let index: Int
        fileprivate init(owner: ObjectIdentifier, pixels: CVPixelBuffer, time: Double,
                         input: MLFeatureProvider, output: MLFeatureProvider, content: CGRect,
                         preprocessMS: Double, inferenceMS: Double, preparationMS: Double,
                         cursor: BatchCursor, index: Int) {
            self.owner=owner; self.pixels=pixels; self.time=time; self.input=input; self.output=output
            self.content=content; self.preprocessMS=preprocessMS; self.inferenceMS=inferenceMS
            self.preparationMS=preparationMS
            self.cursor=cursor; self.index=index
        }
    }

    /// Full-frame prediction is stateless. Confirmation/retry history is touched
    /// only when detectPrepared consumes each result in source order.
    private struct BatchInputs {
        let frames: [(pixels: CVPixelBuffer, time: Double)]
        let inputs: [MLFeatureProvider]
        let rects: [CGRect]
        let start, prepared: Double
    }

    private func batchInputs(_ frames: [(pixels: CVPixelBuffer, time: Double)]) throws -> BatchInputs {
        try Task.checkCancellation()
        guard supportsFrameBatching else { throw BatchError.unsupported }
        guard (1...2).contains(frames.count), frames.allSatisfy({ $0.time.isFinite }),
              zip(frames,frames.dropFirst()).allSatisfy({ $0.time < $1.time }) else { throw BatchError.invalidFrames }
        let start=ProcessInfo.processInfo.systemUptime
        let oldContent=contentRect
        defer { contentRect=oldContent }
        var inputs=[MLFeatureProvider](), rects=[CGRect]()
        for frame in frames {
            try Task.checkCancellation()
            let image=orientedImage(frame.pixels,portrait:false,orientation:nil)
            let provider=try makeInput(from:image)
            guard let source=provider.featureValue(for:"image")?.multiArrayValue,
                  source.dataType == .float32 else { throw BatchError.unsupported }
            let copy=try MLMultiArray(shape:source.shape,dataType:.float32)
            memcpy(copy.dataPointer,source.dataPointer,source.count*MemoryLayout<Float>.size)
            inputs.append(try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(multiArray:copy)]))
            rects.append(contentRect)
        }
        try Task.checkCancellation()
        return BatchInputs(frames:frames,inputs:inputs,rects:rects,start:start,prepared:ProcessInfo.processInfo.systemUptime)
    }

    private func preparedFrames(_ plan: BatchInputs, outputs: [MLFeatureProvider], finished: Double) throws -> [PreparedFrame] {
        try Task.checkCancellation()
        guard outputs.count == plan.frames.count else { throw BatchError.outputCount }
        let divisor=Double(plan.frames.count), cursor=BatchCursor()
        return plan.frames.indices.map { i in
            PreparedFrame(owner:ObjectIdentifier(self),pixels:plan.frames[i].pixels,time:plan.frames[i].time,
                input:plan.inputs[i],output:outputs[i],content:plan.rects[i],
                preprocessMS:(plan.prepared-plan.start)*1000/divisor,inferenceMS:(finished-plan.prepared)*1000/divisor,
                preparationMS:(finished-plan.start)*1000/divisor,cursor:cursor,index:i)
        }
    }

    func prepareBatch(_ frames: [(pixels: CVPixelBuffer, time: Double)]) throws -> [PreparedFrame] {
        let plan=try batchInputs(frames)
        let batch=try model.predictions(from:MLArrayBatchProvider(array:plan.inputs),options:MLPredictionOptions())
        let finished=ProcessInfo.processInfo.systemUptime
        return try preparedFrames(plan,outputs:(0..<batch.count).map {batch.features(at:$0)},finished:finished)
    }

    /// Same two-frame ownership and ordering contract, with independent async
    /// predictions. Only the immutable model inputs cross prediction tasks.
    func prepareBatchAsync(_ frames: [(pixels: CVPixelBuffer, time: Double)]) async throws -> [PreparedFrame] {
        let plan=try autoreleasepool {try batchInputs(frames)}
        let model=self.model
        let outputs=try await withThrowingTaskGroup(of:(Int,MLFeatureProvider).self) { group in
            for (i,input) in plan.inputs.enumerated() {
                group.addTask {(i,try await model.prediction(from:input))}
            }
            var values=[(Int,MLFeatureProvider)]()
            for try await value in group {values.append(value)}
            return values.sorted {$0.0<$1.0}.map(\.1)
        }
        return try preparedFrames(plan,outputs:outputs,finished:ProcessInfo.processInfo.systemUptime)
    }

    func detectPrepared(_ prepared: PreparedFrame) throws -> FrameDetections {
        try Task.checkCancellation()
        guard prepared.owner == ObjectIdentifier(self) else { throw BatchError.wrongDetector }
        guard !prepared.consumed else { throw BatchError.consumed }
        guard prepared.index == prepared.cursor.next else { throw BatchError.outOfOrder }
        prepared.consumed=true
        prepared.cursor.next += 1
        return try detectFrame(prepared.pixels,orientLandscapeAsPortrait:false,timestamp:prepared.time,
                               imageOrientation:nil,prepared:prepared)
    }
    static let ballThreshold = 0.05
    static let personThreshold = 0.5
    static let productionResourceName = "KickLabYOLO26MotionSegmentation"

    static var configuredResourceName: String {
        configuredResourceName(arguments: ProcessInfo.processInfo.arguments, defaults: .standard)
    }

    /// All app entry points use the validated segmentation export. Legacy saved
    /// selections and launch flags must not silently change the production model.
    /// Keep the inputs injectable to cover upgraded installs and old launch setups.
    static func configuredResourceName(arguments: [String], defaults: UserDefaults) -> String {
        productionResourceName
    }

    /// Explicit lookup for standalone model studies. App configuration does not
    /// use this selector; studies must inject a resource into the detector.
    static func resourceName(for arguments: [String]) -> String {
        if arguments.contains("--ssdlite") { return "KickLabDetector" }
        if arguments.contains("--yolo26-motion-segmentation") || arguments.contains("--yolo26-motion-model-only") { return "KickLabYOLO26MotionSegmentation" }
        if arguments.contains("--yolo26-medium-retained") { return "KickLabYOLO26MediumRetained" }
        if arguments.contains("--yolo26-medium-segmentation") { return "KickLabYOLO26MediumSegmentation" }
        if arguments.contains("--yolo26-medium-finetuned") { return "KickLabYOLO26MediumFineTuned" }
        if arguments.contains("--yolo26-medium-benchmark") { return "KickLabYOLO26MediumBenchmark" }
        if arguments.contains("--yolo26-finetuned") { return "KickLabYOLO26SmallFineTuned" }
        if arguments.contains("--yolox-finetuned") || arguments.contains("--yolox-roi") {
            return "KickLabYOLOXTinyFineTuned"
        }
        if arguments.contains("--yolox") {
            return "KickLabYOLOXTiny"
        }
        if arguments.contains("--fasterrcnn") {
            return "KickLabFasterRCNN"
        }
        return productionResourceName
    }

    static func ballThreshold(for resource: String) -> Double {
        switch resource {
        case "KickLabYOLO26SmallFineTuned", "KickLabYOLO26MediumBenchmark": return 0.30
        case "KickLabYOLOXTinyFineTuned": return 0.10
        case "KickLabFasterRCNN": return 0.40
        default: return ballThreshold
        }
    }

    private(set) var lastPreprocessMS: Double = 0
    private(set) var lastInferenceMS: Double = 0
    private(set) var lastTotalMS: Double = 0
    private var contentRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private let model: MLModel
    private let ciContext: CIContext
    private var scratch: CVPixelBuffer?
    let roiEnabled: Bool
    private let roiPolicy = BallROIPolicy()
    private var thumbnail: CVPixelBuffer?
    private var previousThumbnail: [UInt8]?
    // detect() and its crop retries are synchronous on the owning analysis
    // queue. Like `scratch`, these buffers are reused only after prediction ends.
    private var inputArray: MLMultiArray?
    private var inputProvider: MLFeatureProvider?
    private(set) var lastROIView: ROIView?
    private(set) var lastROIReason: String?
    private(set) var fullFrameCount = 0
    private(set) var cropFrameCount = 0

    /// Size of the frame actually handed to the model, after any rotation.
    private(set) var lastInputSize: CGSize = .zero
    /// The exact buffer given to the model, when one was requested.
    private(set) var lastModelInput: CGImage?
    /// Set to request one snapshot of the model's input on the next frame.
    var wantsModelInputSnapshot = false
    /// Why the last frame produced nothing, when it produced nothing.
    private(set) var lastError: String?

    init(resourceName: String? = nil, modelURL: URL? = nil, useROI: Bool? = nil, useMarginalRetry: Bool? = nil, useDirectConfirmation: Bool? = nil) throws {
        let resource = resourceName ?? Self.configuredResourceName
        guard let url = modelURL ?? Bundle.main.url(forResource: resource, withExtension: "mlmodelc") else {
            throw NSError(domain: "KickLab", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(resource) not in bundle"])
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = VideoWorkExecution.cpuOnly ? .cpuOnly : .all
        self.model = try MLModel(contentsOf: url, configuration: configuration)
        guard let shape = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape,
              shape.count == 4, shape[0].intValue == 1, shape[1].intValue == 3,
              shape[2].intValue > 0, shape[3].intValue > 0 else {
            throw NSError(domain: "KickLab", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported detector input shape"])
        }
        inputHeight = shape[2].intValue
        inputWidth = shape[3].intValue
        isYOLOX = resource == "KickLabYOLOXTiny" || resource == "KickLabYOLOXTinyFineTuned"
        let isMotionModel = resource == "KickLabYOLO26MotionSegmentation"
        let arguments=ProcessInfo.processInfo.arguments
        let exportMetadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        let repairedExport = isMotionModel && exportMetadata?["precision"] == "p3_features_fp32"
        batchModelCompatible = isMotionModel && repairedExport
        directConfirmationEnabled = repairedExport && (useDirectConfirmation ?? !arguments.contains("--disable-ball-confirmation"))
        marginalRetryEnabled = repairedExport && (useMarginalRetry ?? !arguments.contains("--disable-marginal-retry"))
        // This repaired export uses the narrow retry, not the older experimental
        // follower which changes otherwise valid detections and juggling counts.
        guardedRecoveryEnabled = isMotionModel && !repairedExport && (arguments.contains("--yolo26-motion-segmentation")
            || (!arguments.contains("--yolo26-motion-model-only") && UserDefaults.standard.string(forKey:"experimentalBallModel") == "motion"))
        hasMaskOutputs = isMotionModel || resource == "KickLabYOLO26MediumSegmentation"
        isYOLO26 = hasMaskOutputs || resource == "KickLabYOLO26SmallFineTuned"
            || resource == "KickLabYOLO26MediumBenchmark" || resource == "KickLabYOLO26MediumFineTuned" || resource == "KickLabYOLO26MediumRetained"
        ciContext = isYOLO26
            ? CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly, .workingColorSpace: NSNull(), .cacheIntermediates: !guardedRecoveryEnabled])
            : CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly])
        roiEnabled = resource == "KickLabYOLOXTinyFineTuned"
            && (useROI ?? ProcessInfo.processInfo.arguments.contains("--yolox-roi"))
        preservesAspect = resource == "KickLabFasterRCNN" || isYOLOX || isYOLO26
        modelName = marginalRetryEnabled ? "YOLO26-M revised masks + marginal retry" : guardedRecoveryEnabled ? "YOLO26-M motion + masks + native recovery (test)" : isMotionModel ? "YOLO26-M motion + masks (model-only test)" : hasMaskOutputs ? "YOLO26-M + masks (pilot)" : roiEnabled ? "YOLOX-Tiny crop v3 (test)" :
            resource == "KickLabYOLO26MediumRetained" ? "YOLO26-M retained (control)" :
            resource == "KickLabYOLO26MediumFineTuned" ? "YOLO26-M fine-tuned (test)" :
            resource == "KickLabYOLO26MediumBenchmark" ? "YOLO26-M pretrained (benchmark)" :
            isYOLO26 ? "YOLO26-S epoch 3 (test)" :
            resource == "KickLabYOLOXTinyFineTuned" ? "YOLOX-Tiny epoch 2 (test)" :
            isYOLOX ? "YOLOX-Tiny (experimental)" :
            (preservesAspect ? "Faster R-CNN (experimental)" : "SSDLite")
        if resource == "KickLabYOLO26MediumFineTuned" || resource == "KickLabYOLO26MediumRetained" || hasMaskOutputs {
            let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            guard let value = metadata?["ball_threshold"], let threshold = Double(value),
                  threshold.isFinite, threshold > 0, threshold < 1 else {
                throw NSError(domain: "KickLab", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Trained Medium is missing its validated confidence threshold"])
            }
            activeBallThreshold = threshold
        } else {
            activeBallThreshold = Self.ballThreshold(for: resource)
        }

    }

    func detect(_ pixelBuffer: CVPixelBuffer, orientLandscapeAsPortrait: Bool = true,
                timestamp: Double? = nil,
                imageOrientation: CGImagePropertyOrientation? = nil) throws -> FrameDetections {
        try detectFrame(pixelBuffer,orientLandscapeAsPortrait:orientLandscapeAsPortrait,
                        timestamp:timestamp,imageOrientation:imageOrientation,prepared:nil)
    }

    private func detectFrame(_ pixelBuffer: CVPixelBuffer, orientLandscapeAsPortrait: Bool,
                             timestamp: Double?, imageOrientation: CGImagePropertyOrientation?,
                             prepared: PreparedFrame?) throws -> FrameDetections {
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastTotalMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 + (prepared?.preparationMS ?? 0) }
        var image = orientedImage(pixelBuffer, portrait: orientLandscapeAsPortrait,
                                  orientation: imageOrientation)
        lastInputSize = image.extent.size
        lastSceneCut = false
        lastFollowKind = "detector"; lastFollowCalls = 1
        if marginalRetryEnabled || directConfirmationEnabled {
            if timestamp == nil { marginalRetry.reset(); directConfirmation.reset() }
            else if try sceneChanged(image) { lastSceneCut = true; marginalRetry.reset(); directConfirmation.reset() }
        }
        if guardedRecoveryEnabled {
            guard let timestamp, timestamp.isFinite else { throw GuardedBallFollower.Failure.timestamp }
            return try guardedDetect(image, timestamp: timestamp)
        }
        var view: ROIView?
        var pendingROI = false
        defer { if pendingROI { _ = try? roiPolicy.observe([]) } }
        if roiEnabled {
            guard let timestamp, timestamp.isFinite else {
                throw NSError(domain: "KickLab", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Crop tracking requires source timestamps"])
            }
            let chosen = try roiPolicy.choose(timestamp: timestamp,
                width: Int(image.extent.width), height: Int(image.extent.height),
                sceneChange: try sceneChanged(image))
            view = chosen; lastROIView = chosen; pendingROI = true
            if chosen.isFull { fullFrameCount += 1 } else { cropFrameCount += 1 }
            image = Self.crop(image, to: chosen)
        }
        let input: MLFeatureProvider
        let out: MLFeatureProvider
        do {
            if let prepared {
                input=prepared.input; out=prepared.output; contentRect=prepared.content
                lastPreprocessMS=prepared.preprocessMS; lastInferenceMS=prepared.inferenceMS
            } else {
                input = try makeInput(from: image)
                let prepared = ProcessInfo.processInfo.systemUptime
                lastPreprocessMS = (prepared - start) * 1000
                out = try model.prediction(from: input)
                lastInferenceMS = (ProcessInfo.processInfo.systemUptime - prepared) * 1000
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        #if DEBUG
        if let timestamp {
            try PipelineParityReview.model(input:input,output:out,time:timestamp,content:contentRect,
                                           sourceSize:lastInputSize,threshold:activeBallThreshold)
        }
        if hasMaskOutputs, ProcessInfo.processInfo.arguments.contains("--effects-mask-review"),
           let timestamp, abs(timestamp - 20.0/30.0) < 0.002 {
            let folder = URL.documentsDirectory.appendingPathComponent("segmentation-native-output")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var shapes: [String: [Int]] = [:]
            for (provider, names) in [(input, ["image"]), (out, ["boxes", "scores", "labels", "mask_coefficients", "mask_prototypes"])] {
                for name in names {
                    guard let values = provider.featureValue(for: name)?.multiArrayValue else { continue }
                    let floats = (0..<values.count).map { values[$0].floatValue }
                    try floats.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name+".bin")) }
                    shapes[name] = values.shape.map(\.intValue)
                }
            }
            try JSONSerialization.data(withJSONObject: shapes).write(to: folder.appendingPathComponent("shapes.json"))
        }
        #endif
        if let view {
            let candidates = try Self.ballCandidates(out, inputWidth: inputWidth,
                inputHeight: inputHeight, view: view)
            let (selected, reason) = try roiPolicy.observe(candidates)
            pendingROI = false; lastROIReason = reason; lastError = nil
            func normalized(_ c: ROICandidate) -> Detection {
                Detection(score: c.score, x: c.x / lastInputSize.width,
                          y: c.y / lastInputSize.height,
                          width: c.width / lastInputSize.width, height: c.height / lastInputSize.height)
            }
            // Cropped people are incomplete. Only full-view observations enter
            // the counter; its bounded person history bridges periodic scans.
            let person: Detection?
            if view.isFull {
                let values = try Self.decodedValues(out, width: inputWidth, height: inputHeight,
                                                   clipTo: contentRect)
                person = values[5] >= Float(Self.personThreshold)
                    ? Detection(score: Double(values[5]),
                        x: (Double(values[6]) - contentRect.minX) / contentRect.width,
                        y: (Double(values[7]) - contentRect.minY) / contentRect.height,
                        width: Double(values[8]) / contentRect.width,
                        height: Double(values[9]) / contentRect.height) : nil
            } else { person = nil }
            return FrameDetections(ball: selected.map(normalized), person: person)
        }
        let result: [Float]
        do { result = try Self.decodedValues(out, width: inputWidth, height: inputHeight,
                                             clipTo: (isYOLOX || isYOLO26) ? contentRect : nil) }
        catch { lastError = error.localizedDescription; throw error }
        lastError = nil

        // Ten reads through the subscript. It respects strides, bounds and
        // backing store by construction - the only access method that has ever
        // agreed with the lab.
        func value(_ i: Int) -> Double { Double(result[i]) }

        func detection(scoreAt s: Int, boxAt b: Int, threshold: Double) -> Detection? {
            let score = value(s)
            guard score >= threshold else { return nil }
            let d = Detection(score: score, x: (value(b) - contentRect.minX) / contentRect.width,
                              y: (value(b + 1) - contentRect.minY) / contentRect.height,
                              width: value(b + 2) / contentRect.width,
                              height: value(b + 3) / contentRect.height)
            // A large delta can overflow exp() to inf inside the model.
            guard d.x.isFinite, d.y.isFinite, d.width.isFinite, d.height.isFinite,
                  d.width > 0, d.height > 0 else { return nil }
            return d
        }

        let direct = FrameDetections(
            ball: detection(scoreAt: Slot.ballScore, boxAt: Slot.ballBox,
                            threshold: activeBallThreshold),
            person: detection(scoreAt: Slot.personScore, boxAt: Slot.personBox,
                              threshold: Self.personThreshold),
            ballMask: hasMaskOutputs ? BallMask.decode(out, content: contentRect,
                sourceSize: lastInputSize, threshold: activeBallThreshold) : nil,
            usesBallMasks: hasMaskOutputs)
        if directConfirmationEnabled {
            let values: [Double] = direct.ball.map { [$0.score, $0.x, $0.y, $0.width, $0.height] } ?? [0,0,0,0,0]
            if let request = directConfirmation.observe(time: timestamp,
                width: Int(lastInputSize.width), height: Int(lastInputSize.height), direct: values) {
                let confirmed = try confirmDirectBall(image, request: request)
                lastFollowKind = confirmed ? "direct_confirmed" : "direct_confirmation_rejected"
                if !confirmed {
                    // A rejected weak object cannot seed the marginal retry or
                    // spend a second crop call on the same frame.
                    marginalRetry.reset()
                    return FrameDetections(ball: nil, person: direct.person, ballMask: nil, usesBallMasks: hasMaskOutputs)
                }
            }
        }
        guard marginalRetryEnabled, let timestamp else { return direct }
        let weak = detection(scoreAt: Slot.ballScore, boxAt: Slot.ballBox, threshold: 0.20)
        return try retryMarginalBall(image, time: timestamp, direct: direct, weak: weak)
    }

    /// Retain the original box and mask after confirmation. The crop supplies
    /// independent current-pixel evidence, never a replacement observation.
    private func confirmDirectBall(_ image: CIImage, request: BallDetectionConfirmation.Request) throws -> Bool {
        lastFollowCalls = 2
        return try autoreleasepool {
            let oldContent = contentRect
            defer { contentRect = oldContent }
            let roi = request.roi
            let rect = CGRect(x: roi[0], y: Int(lastInputSize.height)-roi[1]-roi[3], width: roi[2], height: roi[3])
            let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let began = ProcessInfo.processInfo.systemUptime
            let input = try makeInput(from: crop)
            let prepared = ProcessInfo.processInfo.systemUptime
            let output = try model.prediction(from: input)
            lastPreprocessMS += (prepared-began)*1000
            lastInferenceMS += (ProcessInfo.processInfo.systemUptime-prepared)*1000
            let result = try Self.decodedValues(output, width: inputWidth, height: inputHeight, clipTo: contentRect)
            let ball = [Double(result[0]), (Double(result[1])-contentRect.minX)/contentRect.width,
                (Double(result[2])-contentRect.minY)/contentRect.height,
                Double(result[3])/contentRect.width, Double(result[4])/contentRect.height]
            guard ball[0] >= 0.45,
                  let mask = BallMask.decode(output, content: contentRect, sourceSize: crop.extent.size, threshold: 0.45) else { return false }
            let fill = Double(mask.alpha.filter { $0 >= 128 }.count) / Double(mask.width*mask.height)
            return BallDetectionConfirmation.accepts(request, crop: ball, maskFill: fill)
        }
    }

    /// Keep full-view person and successful ball observations exactly as decoded.
    /// The only extra inference is a current-frame crop after a marginal miss.
    private func retryMarginalBall(_ image: CIImage, time: Double,
                                   direct: FrameDetections, weak: Detection?) throws -> FrameDetections {
        func values(_ ball: Detection?) -> [Double] {
            ball.map { [$0.score,$0.x,$0.y,$0.width,$0.height] } ?? [0,0,0,0,0]
        }
        guard let request = marginalRetry.observe(time: time,
            width: Int(lastInputSize.width), height: Int(lastInputSize.height),
            direct: values(direct.ball), weak: values(weak)) else { return direct }
        lastFollowCalls = 2
        lastFollowKind = "marginal_retry_rejected"
        return try autoreleasepool {
            let oldContent = contentRect
            defer { contentRect = oldContent }
            let roi = request.roi
            let rect = CGRect(x: roi[0], y: Int(lastInputSize.height)-roi[1]-roi[3],
                              width: roi[2], height: roi[3])
            let crop = image.cropped(to: rect).transformed(by:
                CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let began = ProcessInfo.processInfo.systemUptime
            let input = try makeInput(from: crop)
            let prepared = ProcessInfo.processInfo.systemUptime
            let output = try model.prediction(from: input)
            lastPreprocessMS += (prepared-began)*1000
            lastInferenceMS += (ProcessInfo.processInfo.systemUptime-prepared)*1000
            let result = try Self.decodedValues(output, width: inputWidth, height: inputHeight,
                                                clipTo: contentRect)
            let ball = [Double(result[0]),
                        (Double(result[1])-contentRect.minX)/contentRect.width,
                        (Double(result[2])-contentRect.minY)/contentRect.height,
                        Double(result[3])/contentRect.width, Double(result[4])/contentRect.height]
            guard ball[0] >= 0.50,
                  let mask = BallMask.decode(output, content: contentRect,
                      sourceSize: crop.extent.size, threshold: activeBallThreshold) else { return direct }
            let fill = Double(mask.alpha.filter { $0 >= 128 }.count) / Double(mask.width*mask.height)

            guard let mapped = MarginalBallRetry.accept(request, crop: ball, maskFill: fill)
            else { return direct }
            let mappedMask = BallMask(rect: CGRect(
                x: (Double(roi[0])+mask.rect.minX*Double(roi[2]))/lastInputSize.width,
                y: (Double(roi[1])+mask.rect.minY*Double(roi[3]))/lastInputSize.height,
                width: mask.rect.width*Double(roi[2])/lastInputSize.width,
                height: mask.rect.height*Double(roi[3])/lastInputSize.height),
                width: mask.width, height: mask.height, alpha: mask.alpha)
            lastFollowKind = "marginal_retry"
            return FrameDetections(ball: Detection(score: mapped[0], x: mapped[1], y: mapped[2],
                width: mapped[3], height: mapped[4]), person: direct.person,
                ballMask: mappedMask, usesBallMasks: true)
        }
    }

    /// All contextual requests use the same model. Only compact masks/boxes
    /// survive a request; prototype tensors are released inside autoreleasepool.
    private func guardedDetect(_ image: CIImage, timestamp: Double) throws -> FrameDetections {
        let scale = 1920.0 / max(image.extent.width, image.extent.height)
        let size = CGSize(width: (image.extent.width*scale).rounded(), height: (image.extent.height*scale).rounded())
        let changed = try sceneChanged(image)
        if guardedDimensions != size || changed {
            guardedFollower.reset(); nativePixels.reset(); guardedDimensions=size
        }
        let flow = nativePixels.update(image, size: size)
        var person: Detection?
        lastInferenceMS=0; lastPreprocessMS=0
        let result = try guardedFollower.step(time: timestamp, size: size, flow: flow, sceneCut: changed) { view in
            try autoreleasepool {
                let crop = CGRect(x: Double(view.x)/size.width*image.extent.width,
                    y: (1-view.rect.maxY/size.height)*image.extent.height,
                    width: Double(view.width)/size.width*image.extent.width,
                    height: Double(view.height)/size.height*image.extent.height)
                let patch=image.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
                let start=ProcessInfo.processInfo.systemUptime
                let input=try self.makeInput(from:patch), prepared=ProcessInfo.processInfo.systemUptime
                let output=try self.model.prediction(from:input)
                self.lastPreprocessMS += (prepared-start)*1000
                self.lastInferenceMS += (ProcessInfo.processInfo.systemUptime-prepared)*1000
                let content=self.contentRect
                if view.x == 0 && view.y == 0 && view.width == Int(size.width) && view.height == Int(size.height) {
                    self.fullFrameCount += 1
                    let values=try Self.decodedValues(output,width:self.inputWidth,height:self.inputHeight,clipTo:content)
                    if values[5] >= Float(Self.personThreshold) {
                        person=Detection(score:Double(values[5]),x:(Double(values[6])-content.minX)/content.width,
                            y:(Double(values[7])-content.minY)/content.height,width:Double(values[8])/content.width,height:Double(values[9])/content.height)
                    }
                } else { self.cropFrameCount += 1 }
                guard let boxes=output.featureValue(for:"boxes")?.multiArrayValue,
                      let scores=output.featureValue(for:"scores")?.multiArrayValue,
                      let labels=output.featureValue(for:"labels")?.multiArrayValue else { throw NSError(domain:"KickLab",code:6) }
                var candidates: [(Int,FollowHit)] = []
                for i in 0..<scores.count where labels[i].intValue == 37 {
                    let score=Double(scores[i].floatValue)
                    guard score.isFinite, score >= self.activeBallThreshold else { continue }
                    let b=(0..<4).map { Double(boxes[[NSNumber(value:i),NSNumber(value:$0)]].floatValue)/640 }
                    guard b.allSatisfy(\.isFinite),b[2]>b[0],b[3]>b[1] else { continue }
                    let r=CGRect(x:b[0],y:b[1],width:b[2]-b[0],height:b[3]-b[1]).intersection(content)
                    guard !r.isNull, !r.isEmpty else { continue }
                    let mapped=CGRect(x:Double(view.x)+(r.minX-content.minX)/content.width*Double(view.width),
                        y:Double(view.y)+(r.minY-content.minY)/content.height*Double(view.height),
                        width:r.width/content.width*Double(view.width),height:r.height/content.height*Double(view.height))
                    candidates.append((i,FollowHit(rect:mapped,score:score)))
                }
                candidates.sort { $0.1.score == $1.1.score ? $0.0 < $1.0 : $0.1.score > $1.1.score }
                var hits: [FollowHit] = []
                for (index,var hit) in candidates {
                    if hits.contains(where: { other in
                        let overlap=other.rect.intersection(hit.rect)
                        let area=overlap.isNull ? 0 : overlap.width*overlap.height
                        return area/max(1e-9,other.rect.width*other.rect.height+hit.rect.width*hit.rect.height-area) > 0.65
                    }) { continue }
                    if let m=BallMask.decode(output,content:content,sourceSize:patch.extent.size,threshold:self.activeBallThreshold,selectedIndex:index) {
                        hit.mask=BallMask(rect:CGRect(x:(Double(view.x)+m.rect.minX*Double(view.width))/size.width,
                            y:(Double(view.y)+m.rect.minY*Double(view.height))/size.height,
                            width:m.rect.width*Double(view.width)/size.width,height:m.rect.height*Double(view.height)/size.height),
                            width:m.width,height:m.height,alpha:m.alpha)
                    }
                    hits.append(hit)
                }
                return hits
            }
        }
        lastFollowKind=result.kind; lastFollowCalls=result.calls; lastError=nil
        if let hit=result.hit, result.kind != "pixel_track" { nativePixels.seed(hit,image:image,size:size) }
        else if result.hit == nil { nativePixels.reset() }
        let ball=result.hit.map { Detection(score:$0.score,x:$0.center.x/size.width,y:$0.center.y/size.height,
            width:$0.rect.width/size.width,height:$0.rect.height/size.height) }
        return FrameDetections(ball:ball,person:person,ballMask:result.hit?.mask,usesBallMasks:true)
    }

    // MARK: - Input

    /// NMS precedes source clipping, as in torchvision/YOLOX. Filtering at .10
    /// cannot remove a higher-scoring survivor, and bounds work to useful boxes.
    static func ballCandidates(_ out: MLFeatureProvider, inputWidth: Int, inputHeight: Int,
                               view: ROIView) throws -> [ROICandidate] {
        guard let boxes = out.featureValue(for: "boxes")?.multiArrayValue,
              let scores = out.featureValue(for: "scores")?.multiArrayValue,
              let labels = out.featureValue(for: "labels")?.multiArrayValue,
              boxes.shape.count == 2, boxes.shape[1].intValue == 4,
              boxes.shape[0].intValue == scores.count, labels.count == scores.count else {
            throw NSError(domain: "KickLab", code: 6)
        }
        var proposed: [(index: Int, d: ROICandidate)] = []
        for i in 0..<scores.count where labels[i].intValue == 37 {
            let score = Double(scores[i].floatValue)
            guard score.isFinite, score >= 0.10 else { continue }
            let box = (0..<4).map { Double(boxes[[NSNumber(value:i), NSNumber(value:$0)]].floatValue) }
            let d = ROICandidate(box: box, score: score)
            if d.valid { proposed.append((i, d)) }
        }
        proposed.sort { $0.d.score == $1.d.score ? $0.index < $1.index : $0.d.score > $1.d.score }
        func overlap(_ a: ROICandidate, _ b: ROICandidate) -> Double {
            let area = max(0, min(a.box[2], b.box[2]) - max(a.box[0], b.box[0]))
                * max(0, min(a.box[3], b.box[3]) - max(a.box[1], b.box[1]))
            return area / max(1e-9, a.width * a.height + b.width * b.height - area)
        }
        var kept: [ROICandidate] = []
        for (_, d) in proposed where !kept.contains(where: { overlap($0, d) > 0.65 }) { kept.append(d) }
        let ratio = min(Double(inputWidth) / Double(view.width), Double(inputHeight) / Double(view.height))
        return kept.compactMap { d in
            let box = d.box.enumerated().map { column, v in
                let size = Double(column % 2 == 0 ? view.width : view.height)
                let offset = Double(view.rect[column % 2])
                return max(0, min(size, v / ratio)) + offset
            }
            let mapped = ROICandidate(box: box, score: d.score)
            return mapped.valid ? mapped : nil
        }
    }

    private func orientedImage(_ pixels: CVPixelBuffer, portrait: Bool,
                               orientation: CGImagePropertyOrientation? = nil) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixels)
        if let orientation { image = image.oriented(orientation) }
        else if portrait && image.extent.width > image.extent.height { image = image.oriented(.right) }
        return image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Policy uses top-down source pixels; Core Image uses a bottom-left origin.
    static func crop(_ image: CIImage, to view: ROIView) -> CIImage {
        let rect = CGRect(x: CGFloat(view.rect[0]), y: image.extent.height - CGFloat(view.rect[3]),
                          width: CGFloat(view.width), height: CGFloat(view.height))
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private func sceneChanged(_ image: CIImage) throws -> Bool {
        if thumbnail == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &thumbnail)
        }
        guard let buffer = thumbnail else { throw NSError(domain: "KickLab", code: 4) }
        ciContext.render(image.samplingLinear().transformed(by: CGAffineTransform(
            scaleX: 64 / image.extent.width, y: 64 / image.extent.height)), to: buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let pointer = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        var current = [UInt8](repeating: 0, count: 64 * 64 * 3)
        var total = 0
        for y in 0..<64 { for x in 0..<64 { for c in 0..<3 {
            let i = (y * 64 + x) * 3 + c, value = pointer[y * stride + x * 4 + c]
            current[i] = value
            if let old = previousThumbnail { total += abs(Int(value) - Int(old[i])) }
        } } }
        previousThumbnail = current
        return Double(total) / Double(current.count * 255) > 0.22
    }

    /// Convert either output contract to [score,cx,cy,w,h] for ball then person.
    /// The Faster R-CNN candidates are already decoded and suppressed by NMS.
    static func decodedValues(_ out: MLFeatureProvider, width: Int, height: Int,
                              clipTo content: CGRect? = nil) throws -> [Float] {
        if let values = out.featureValue(for: "detection")?.multiArrayValue,
           values.count == Slot.count {
            return (0..<Slot.count).map { values[$0].floatValue }
        }
        guard let boxes = out.featureValue(for: "boxes")?.multiArrayValue,
              let scores = out.featureValue(for: "scores")?.multiArrayValue,
              let labels = out.featureValue(for: "labels")?.multiArrayValue,
              boxes.shape.count == 2, boxes.shape[1].intValue == 4,
              boxes.shape[0].intValue == scores.count, scores.count == labels.count,
              width > 0, height > 0 else {
            throw NSError(domain: "KickLab", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported detector output shape"])
        }
        var result = [Float](repeating: 0, count: Slot.count)
        for i in 0..<scores.count {
            let label = labels[i].intValue
            guard label == 37 || label == 1 else { continue }
            let slot = label == 37 ? 0 : 5
            let score = scores[i].floatValue
            guard score.isFinite, score > result[slot] else { continue }
            func coordinate(_ column: Int) -> Float {
                boxes[[NSNumber(value: i), NSNumber(value: column)]].floatValue
            }
            var x1 = coordinate(0) / Float(width), y1 = coordinate(1) / Float(height)
            var x2 = coordinate(2) / Float(width), y2 = coordinate(3) / Float(height)
            guard [x1, y1, x2, y2].allSatisfy({ $0.isFinite }) else { continue }
            if let content {
                x1 = max(Float(content.minX), min(Float(content.maxX), x1))
                x2 = max(Float(content.minX), min(Float(content.maxX), x2))
                y1 = max(Float(content.minY), min(Float(content.maxY), y1))
                y2 = max(Float(content.minY), min(Float(content.maxY), y2))
            }
            guard [x1, y1, x2, y2].allSatisfy({ $0.isFinite }), x2 > x1, y2 > y1 else { continue }
            result.replaceSubrange(slot..<(slot + 5), with: [score, (x1+x2)/2, (y1+y2)/2, x2-x1, y2-y1])
        }
        return result
    }

    /// Camera frame to RGB 0-1 for SSD/Faster R-CNN, or official BGR 0-255 for YOLOX.
    private func makeInput(from image: CIImage) throws -> MLFeatureProvider {
        if inputArray == nil {
            let array = try MLMultiArray(shape: [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)],
                                        dataType: .float32)
            inputProvider = try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(multiArray:array)])
            inputArray = array
        }
        guard let array=inputArray, let provider=inputProvider else { throw NSError(domain:"KickLab",code:3) }
        let resized = try square(image)
        CVPixelBufferLockBaseAddress(resized, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(resized, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(resized) else {
            throw NSError(domain: "KickLab", code: 3)
        }
        let stride = CVPixelBufferGetBytesPerRow(resized)
        let src = base.assumingMemoryBound(to: UInt8.self)
        // Safe here: this is a buffer we created, contiguous and CPU-backed.
        let dst = UnsafeMutablePointer<Float>(OpaquePointer(array.dataPointer))
        Self.fillInput(src, rowBytes:stride, width:inputWidth,height:inputHeight,bgr:isYOLOX,output:dst)
        return provider
    }

    private static let normalizedBytes: [Float] = (0...255).map { Float($0)/255.0 }

    /// Preserve the exact Float division for every possible source byte while
    /// avoiding millions of conversions/divisions per frame. Honor row padding.
    static func fillInput(_ src: UnsafePointer<UInt8>, rowBytes: Int, width: Int, height: Int,
                          bgr: Bool, output dst: UnsafeMutablePointer<Float>) {
        let plane=width*height
        let lookup=normalizedBytes
        for y in 0..<height {
            let row = src + y * rowBytes
            for x in 0..<width {
                let p = row + x * 4
                let i = y * width + x
                if bgr {
                    dst[i] = Float(p[0])
                    dst[plane + i] = Float(p[1])
                    dst[2 * plane + i] = Float(p[2])
                } else {
                    dst[i] = lookup[Int(p[2])]
                    dst[plane + i] = lookup[Int(p[1])]
                    dst[2 * plane + i] = lookup[Int(p[0])]
                }
            }
        }
    }

    /// Orient the frame, then resize to the model input. Faster R-CNN preserves
    /// aspect ratio with letterboxing; SSDLite keeps its original square resize.
    private func square(_ image: CIImage) throws -> CVPixelBuffer {
        if scratch == nil {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, inputWidth, inputHeight, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &buffer)
            scratch = buffer
        }
        guard let out = scratch else { throw NSError(domain: "KickLab", code: 4) }

        let sx = CGFloat(inputWidth) / image.extent.width
        let sy = CGFloat(inputHeight) / image.extent.height
        if isYOLOX {
            let scale = min(sx, sy)
            // Match upstream's integer truncation and top-left image placement.
            // Core Image's origin is bottom-left; model tensor rows are top-down.
            let resizedWidth = floor(image.extent.width * scale)
            let resizedHeight = floor(image.extent.height * scale)
            contentRect = CGRect(x: 0, y: 0,
                width: image.extent.width * scale / CGFloat(inputWidth),
                height: image.extent.height * scale / CGFloat(inputHeight))
            let placed = image.samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: resizedWidth / image.extent.width,
                                                   y: resizedHeight / image.extent.height))
                .transformed(by: CGAffineTransform(translationX: 0,
                                                   y: CGFloat(inputHeight) - resizedHeight))
            let grey = CGFloat(114.0 / 255.0)
            let background = CIImage(color: CIColor(red: grey, green: grey, blue: grey))
                .cropped(to: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
            ciContext.render(placed.composited(over: background), to: out)
        } else if isYOLO26 {
            let scale = min(sx, sy)
            // Ultralytics LetterBox: rounded size, integer centered padding,
            // RGB /255 and 114 grey. This differs from YOLOX preprocessing.
            let width = (image.extent.width * scale).rounded(.toNearestOrEven)
            let height = (image.extent.height * scale).rounded(.toNearestOrEven)
            let left = ((CGFloat(inputWidth) - width) / 2 - 0.1).rounded(.toNearestOrEven)
            let top = ((CGFloat(inputHeight) - height) / 2 - 0.1).rounded(.toNearestOrEven)
            contentRect = CGRect(x: left / CGFloat(inputWidth), y: top / CGFloat(inputHeight),
                width: image.extent.width * scale / CGFloat(inputWidth),
                height: image.extent.height * scale / CGFloat(inputHeight))
            let placed = image.clampedToExtent().samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: width / image.extent.width,
                                                   y: height / image.extent.height))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                .transformed(by: CGAffineTransform(translationX: left,
                                                   y: CGFloat(inputHeight) - top - height))
            let grey = CGFloat(114.0 / 255.0)
            let background = CIImage(color: CIColor(red: grey, green: grey, blue: grey))
                .cropped(to: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
            ciContext.render(placed.composited(over: background), to: out)
        } else if preservesAspect {
            let scale = min(sx, sy)
            let width = image.extent.width * scale
            let height = image.extent.height * scale
            let dx = (CGFloat(inputWidth) - width) / 2
            let dy = (CGFloat(inputHeight) - height) / 2
            contentRect = CGRect(x: dx / CGFloat(inputWidth), y: dy / CGFloat(inputHeight),
                                 width: width / CGFloat(inputWidth), height: height / CGFloat(inputHeight))
            let placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
            ciContext.render(placed.composited(over: background), to: out)
        } else {
            contentRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            ciContext.render(image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: out)
        }

        // Snapshotting costs a GPU->CPU readback; only when asked.
        if wantsModelInputSnapshot {
            lastModelInput = ciContext.createCGImage(
                CIImage(cvPixelBuffer: out),
                from: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
            wantsModelInputSnapshot = false
        }
        return out
    }
}

#if DEBUG
nonisolated extension BallDetector {
    /// Immutable real inputs for bounded execution-mode measurements only.
    func reviewInput(_ pixels: CVPixelBuffer) throws -> MLFeatureProvider {
        let input=try makeInput(from:orientedImage(pixels,portrait:false,orientation:nil))
        let source=input.featureValue(for:"image")!.multiArrayValue!
        let copy=try MLMultiArray(shape:source.shape,dataType:.float32)
        memcpy(copy.dataPointer,source.dataPointer,source.count*MemoryLayout<Float>.size)
        return try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(multiArray:copy)])
    }
    func reviewSerial(_ input:MLFeatureProvider) throws -> MLFeatureProvider {try model.prediction(from:input)}
    func reviewBatch(_ inputs:[MLFeatureProvider]) throws -> MLBatchProvider {
        try model.predictions(from:MLArrayBatchProvider(array:inputs),options:MLPredictionOptions())
    }
    func reviewAsync(_ input:MLFeatureProvider) async throws -> MLFeatureProvider {try await model.prediction(from:input)}
}
#endif

// Appearance-only access to current-pixel crops. Temporal detector state stays
// with the full-frame baseline; this method never seeds its confirmation/retry.
nonisolated extension BallDetector {
    func inferVisualCrop(_ pixels: CVPixelBuffer, roi: CGRect) throws -> FrameDetections {
        try Task.checkCancellation()
        guard supportsDistantVisualRecovery else { return FrameDetections(ball:nil,person:nil) }
        let old = contentRect
        defer { contentRect = old }
        let image = orientedImage(pixels, portrait: false, orientation: nil)
        let rect = CGRect(x: roi.minX, y: image.extent.height-roi.maxY, width: roi.width, height: roi.height)
        let patch = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let output = try model.prediction(from: makeInput(from: patch))
        let result = try Self.decodedValues(output, width: inputWidth, height: inputHeight, clipTo: contentRect)
        let score = Double(result[0])
        guard score.isFinite, score > 0 else { return FrameDetections(ball:nil, person:nil) }
        let x = (Double(result[1])-contentRect.minX)/contentRect.width
        let y = (Double(result[2])-contentRect.minY)/contentRect.height
        let w = Double(result[3])/contentRect.width, h = Double(result[4])/contentRect.height
        let size = image.extent.size
        let ball = Detection(score:score, x:(roi.minX+x*roi.width)/size.width,
            y:(roi.minY+y*roi.height)/size.height, width:w*roi.width/size.width, height:h*roi.height/size.height)
        let localMask = BallMask.decode(output, content:contentRect, sourceSize:patch.extent.size, threshold:0.5,
                                       sourceBorder:4)
        let mask = localMask.map { m in BallMask(rect:CGRect(x:(roi.minX+m.rect.minX*roi.width)/size.width,
            y:(roi.minY+m.rect.minY*roi.height)/size.height, width:m.rect.width*roi.width/size.width,
            height:m.rect.height*roi.height/size.height), width:m.width, height:m.height, alpha:m.alpha) }
        return FrameDetections(ball:ball, person:nil, ballMask:mask, usesBallMasks:true)
    }
}
