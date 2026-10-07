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

final class BallDetector {
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
    let guardedRecoveryEnabled: Bool
    private let guardedFollower = GuardedBallFollower()
    private let nativePixels = NativeBallPixelTrack()
    private(set) var lastFollowKind = "detector"
    private(set) var lastFollowCalls = 1
    private var guardedDimensions = CGSize.zero
    let hasMaskOutputs: Bool
    let modelName: String
    let activeBallThreshold: Double
    static let ballThreshold = 0.05
    static let personThreshold = 0.5

    static var configuredResourceName: String {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { $0.hasPrefix("--yolo") || $0 == "--ssdlite" || $0 == "--fasterrcnn" }) {
            return resourceName(for: arguments)
        }
        let selected = UserDefaults.standard.string(forKey: "experimentalBallModel") ?? "default"
        if selected == "motion" || selected == "motionModel" { return "KickLabYOLO26MotionSegmentation" }
        if selected == "segmentation" { return "KickLabYOLO26MediumSegmentation" }
        if selected == "medium" { return "KickLabYOLO26MediumRetained" }
        return resourceName(for: arguments)
    }

    static func resourceName(for arguments: [String]) -> String {
        // Faster R-CNN exceeded 3 GB during the phone experiment and crashed.
        // Keep the working mobile model as the default, even when both are bundled.
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
        return "KickLabDetector"
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

    init(resourceName: String? = nil, modelURL: URL? = nil, useROI: Bool? = nil) throws {
        let resource = resourceName ?? Self.configuredResourceName
        guard let url = modelURL ?? Bundle.main.url(forResource: resource, withExtension: "mlmodelc") else {
            throw NSError(domain: "KickLab", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(resource) not in bundle"])
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
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
        guardedRecoveryEnabled = isMotionModel && (arguments.contains("--yolo26-motion-segmentation")
            || (!arguments.contains("--yolo26-motion-model-only") && UserDefaults.standard.string(forKey:"experimentalBallModel") == "motion"))
        hasMaskOutputs = isMotionModel || resource == "KickLabYOLO26MediumSegmentation"
        isYOLO26 = hasMaskOutputs || resource == "KickLabYOLO26SmallFineTuned"
            || resource == "KickLabYOLO26MediumBenchmark" || resource == "KickLabYOLO26MediumFineTuned" || resource == "KickLabYOLO26MediumRetained"
        ciContext = isYOLO26
            ? CIContext(options: [.useSoftwareRenderer: false, .workingColorSpace: NSNull(), .cacheIntermediates: !guardedRecoveryEnabled])
            : CIContext(options: [.useSoftwareRenderer: false])
        roiEnabled = resource == "KickLabYOLOXTinyFineTuned"
            && (useROI ?? ProcessInfo.processInfo.arguments.contains("--yolox-roi"))
        preservesAspect = resource == "KickLabFasterRCNN" || isYOLOX || isYOLO26
        modelName = guardedRecoveryEnabled ? "YOLO26-M motion + masks + native recovery (test)" : isMotionModel ? "YOLO26-M motion + masks (model-only test)" : hasMaskOutputs ? "YOLO26-M + masks (pilot)" : roiEnabled ? "YOLOX-Tiny crop v3 (test)" :
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
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastTotalMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        var image = orientedImage(pixelBuffer, portrait: orientLandscapeAsPortrait,
                                  orientation: imageOrientation)
        lastInputSize = image.extent.size
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
            input = try makeInput(from: image)
            let prepared = ProcessInfo.processInfo.systemUptime
            lastPreprocessMS = (prepared - start) * 1000
            out = try model.prediction(from: input)
            lastInferenceMS = (ProcessInfo.processInfo.systemUptime - prepared) * 1000
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        #if DEBUG
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

        return FrameDetections(
            ball: detection(scoreAt: Slot.ballScore, boxAt: Slot.ballBox,
                            threshold: activeBallThreshold),
            person: detection(scoreAt: Slot.personScore, boxAt: Slot.personBox,
                              threshold: Self.personThreshold),
            ballMask: hasMaskOutputs ? BallMask.decode(out, content: contentRect,
                sourceSize: lastInputSize, threshold: activeBallThreshold) : nil,
            usesBallMasks: hasMaskOutputs)
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
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)],
                                     dataType: .float32)
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
        let plane = inputWidth * inputHeight

        // BGRA in, planar RGB out, scaled to 0-1.
        for y in 0..<inputHeight {
            let row = src + y * stride
            for x in 0..<inputWidth {
                let p = row + x * 4
                let i = y * inputWidth + x
                if isYOLOX {
                    dst[i] = Float(p[0])
                    dst[plane + i] = Float(p[1])
                    dst[2 * plane + i] = Float(p[2])
                } else {
                    dst[i] = Float(p[2]) / 255.0
                    dst[plane + i] = Float(p[1]) / 255.0
                    dst[2 * plane + i] = Float(p[0]) / 255.0
                }
            }
        }
        return try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(multiArray: array)])
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
