import CoreImage
import CoreML
import CoreVideo
import Foundation

/// RF-DETR Seg Small dev.8: stretch RGB to 384 square, normalize as trained,
/// and return boxes/masks in upright source coordinates. Owns only reusable input
/// storage; no model-output tensors escape decoding into the recording track.
nonisolated final class RFSegBridge {
    /// Square model input side. Masks are a quarter of it (96 at 384).
    let edge: Int
    private var pixels: CVPixelBuffer?
    private var array: MLMultiArray?
    private var provider: MLFeatureProvider?

    init(edge: Int = RFInputNormalization.edge) { self.edge = edge }

    #if DEBUG
    /// Weak-reference lifecycle checks must not keep the buffer alive themselves.
    var inputBufferForReview: CVPixelBuffer? { pixels }

    /// Camera coordinates are top-left, including a nonzero crop origin. Read
    /// the BGRA rows directly so a wall crop needs no extra image allocation.
    func wallInput(_ buffer: CVPixelBuffer, crop: CGRect) throws -> MLFeatureProvider {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              crop.width >= 1, crop.height >= 1, crop.minX >= 0, crop.minY >= 0,
              crop.maxX <= Double(CVPixelBufferGetWidth(buffer)),
              crop.maxY <= Double(CVPixelBufferGetHeight(buffer)) else { throw failure("Invalid wall crop") }
        if array == nil {
            let value = try MLMultiArray(shape: [1, 3, NSNumber(value: edge), NSNumber(value: edge)], dataType: .float32)
            array = value; provider = try MLDictionaryFeatureProvider(dictionary: ["tensors": value])
        }
        guard let array, let provider else { throw failure("RF input unavailable") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw failure("RF pixels unavailable") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        RFInputNormalization.normalizeBGRA(base.assumingMemoryBound(to: UInt8.self)
            .advanced(by: Int(crop.minY) * stride + Int(crop.minX) * 4),
            width: Int(crop.width), height: Int(crop.height), rowBytes: stride,
            into: array.dataPointer.assumingMemoryBound(to: Float.self), edge: edge)
        return provider
    }

    func wallCandidates(_ out: MLFeatureProvider) throws -> [Detection] {
        guard let boxes = out.featureValue(for: "concat_2")?.multiArrayValue,
              let scores = out.featureValue(for: "linear_122")?.multiArrayValue,
              boxes.shape.map(\.intValue) == [1, 100, 4], scores.shape.map(\.intValue) == [1, 100, 91] else {
            throw failure("Unexpected wall output")
        }
        let bs = boxes.strides.map(\.intValue), ss = scores.strides.map(\.intValue)
        return (0..<100).compactMap { q -> Detection? in
            let logit = Self.value(scores, q * ss[1] + 37 * ss[2])
            guard logit.isFinite else { return nil }
            let score = 1 / (1 + exp(-logit)), o = q * bs[1]
            let x = Self.value(boxes, o), y = Self.value(boxes, o + bs[2])
            let w = Self.value(boxes, o + 2 * bs[2]), h = Self.value(boxes, o + 3 * bs[2])
            guard score >= 0.08, [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
            return Detection(score: score, x: x, y: y, width: w, height: h)
        }.sorted { $0.score > $1.score }.prefix(6).map { $0 }
    }
    #endif

    /// Both bundled functions are supported in Release as well as Debug.
    /// Other patch-aligned grids remain explicit debug studies only.
    static func supports(edge: Int) -> Bool {
        if RFInputResolution(rawValue: edge) != nil { return true }
        #if DEBUG && TOUCH_COUNTING_DEBUG
        return edge == RFInputNormalization.edge || (edge % 24 == 0 && (192...360).contains(edge))
        #else
        return false
        #endif
    }

    @discardableResult
    static func validate(_ description: MLModelDescription, outputType: MLMultiArrayDataType = .float32) throws -> Int {
        let edge = description.inputDescriptionsByName["tensors"]?.multiArrayConstraint?.shape.last?.intValue ?? 0
        let expected = ["concat_2": [1, 100, 4], "linear_122": [1, 100, 91], "add_62": [1, 100, edge / 4, edge / 4]]
        guard outputType == .float16 || outputType == .float32, supports(edge: edge),
              let input = description.inputDescriptionsByName["tensors"]?.multiArrayConstraint,
              input.shape.map(\.intValue) == [1, 3, edge, edge], input.dataType == .float32,
              expected.allSatisfy({ name, shape in
                  guard let output = description.outputDescriptionsByName[name]?.multiArrayConstraint else { return false }
                  return output.shape.map(\.intValue) == shape && output.dataType == outputType
              }) else {
            throw NSError(domain: "RFDETRSmall", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "RF-DETR Small model does not match its selected precision and tensor contract."])
        }
        return edge
    }

    func input(image: CIImage, context: CIContext) throws -> MLFeatureProvider {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { throw failure("Empty source frame") }
        if pixels == nil || CVPixelBufferGetWidth(pixels!) != width || CVPixelBufferGetHeight(pixels!) != height {
            // Core Video writes an owning reference through this C out-pointer.
            // Do not overwrite an already-owned property through that pointer:
            // each different crop size would strand the previous IOSurface.
            var replacement: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &replacement)
            guard result == kCVReturnSuccess, let replacement else { throw failure("Cannot allocate RF input buffer") }
            pixels = replacement
        }
        if array == nil {
            let value = try MLMultiArray(shape: [1, 3, NSNumber(value: edge), NSNumber(value: edge)], dataType: .float32)
            array = value
            provider = try MLDictionaryFeatureProvider(dictionary: ["tensors": value])
        }
        guard let pixels, let array, let provider else { throw failure("RF input unavailable") }
        context.render(image, to: pixels, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw failure("RF pixels unavailable") }
        RFInputNormalization.normalizeBGRA(base.assumingMemoryBound(to: UInt8.self), width: width,
            height: height, rowBytes: CVPixelBufferGetBytesPerRow(pixels), into: array.dataPointer.assumingMemoryBound(to: Float.self), edge: edge)
        return provider
    }

    func decode(_ out: MLFeatureProvider, sourceSize: CGSize, threshold: Double,
                includeAuxiliary: Bool = true, includeMasks: Bool = true) throws -> FrameDetections {
        guard let boxes = out.featureValue(for: "concat_2")?.multiArrayValue,
              let scores = out.featureValue(for: "linear_122")?.multiArrayValue,
              let masks = out.featureValue(for: "add_62")?.multiArrayValue,
              boxes.shape.map(\.intValue) == [1, 100, 4], scores.shape.map(\.intValue) == [1, 100, 91],
              masks.shape.map(\.intValue) == [1, 100, edge / 4, edge / 4] else { throw failure("Unexpected RF Small output") }
        let bs = boxes.strides.map(\.intValue), ss = scores.strides.map(\.intValue)
        func selected(_ label: Int, _ threshold: Double) -> (Int, Detection)? {
            var query = 0, best = -Double.infinity
            for q in 0..<100 {
                let value = Self.value(scores, q * ss[1] + label * ss[2])
                if value > best { best = value; query = q }
            }
            guard best.isFinite else { return nil }
            let score = 1 / (1 + exp(-best))
            guard score.isFinite, score >= threshold else { return nil }
            let offset = query * bs[1]
            let x = Self.value(boxes, offset), y = Self.value(boxes, offset + bs[2])
            let w = Self.value(boxes, offset + 2 * bs[2]), h = Self.value(boxes, offset + 3 * bs[2])
            guard [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
            let rect = CGRect(x: x-w/2, y: y-h/2, width: w, height: h).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !rect.isNull, !rect.isEmpty else { return nil }
            return (query, Detection(score: score, x: rect.midX, y: rect.midY, width: rect.width, height: rect.height))
        }
        let ball = selected(37, threshold)
        let person = includeAuxiliary ? selected(1, BallDetector.personThreshold) : nil
        var people: [Detection] = []
        if includeAuxiliary {
            let candidates: [Detection] = (0..<100).compactMap { query in
                let logit = Self.value(scores, query * ss[1] + ss[2])
                guard logit.isFinite else { return nil }
                let score = 1 / (1 + exp(-logit)), offset = query * bs[1]
                guard score >= BallDetector.personThreshold else { return nil }
                let x = Self.value(boxes, offset), y = Self.value(boxes, offset + bs[2])
                let w = Self.value(boxes, offset + 2*bs[2]), h = Self.value(boxes, offset + 3*bs[2])
                guard [x,y,w,h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
                let rect = CGRect(x: x-w/2, y: y-h/2, width: w, height: h)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !rect.isNull, !rect.isEmpty else { return nil }
                return Detection(score: score, x: rect.midX, y: rect.midY, width: rect.width, height: rect.height)
            }
            for candidate in candidates.sorted(by: { $0.score > $1.score }) {
                let box = PersonBox(x: candidate.x, y: candidate.y, width: candidate.width, height: candidate.height)
                guard !people.contains(where: {
                    box.iou(.init(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) > 0.75
                }) else { continue }
                people.append(candidate)
                if people.count == 8 { break }
            }
        }
        let mask = includeAuxiliary && includeMasks ? ball.flatMap { Self.mask(masks, query: $0.0, ball: $0.1, source: sourceSize) } : nil
        return FrameDetections(ball: ball?.1, person: person?.1, people: people, ballMask: mask, usesBallMasks: includeAuxiliary && includeMasks)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "RFDETRSmall", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func value(_ a: MLMultiArray, _ index: Int) -> Double {
        switch a.dataType {
        case .float16: return Double(a.dataPointer.assumingMemoryBound(to: Float16.self)[index])
        case .float32: return Double(a.dataPointer.assumingMemoryBound(to: Float.self)[index])
        default: return a[index].doubleValue
        }
    }

    private static func mask(_ a: MLMultiArray, query: Int, ball: Detection, source: CGSize) -> BallMask? {
        let side = a.shape[3].intValue, grid = Double(side)
        let rect = CGRect(x: ball.x-ball.width/2, y: ball.y-ball.height/2, width: ball.width, height: ball.height)
            .insetBy(dx: -1.0/grid, dy: -1.0/grid).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let w = min(128, max(8, Int(ceil(rect.width * source.width))))
        let h = min(128, max(8, Int(ceil(rect.height * source.height))))
        let strides = a.strides.map(\.intValue), offset = query * a.strides[1].intValue
        func logit(_ x: Int, _ y: Int) -> Double { value(a, offset + min(side-1, max(0, y)) * strides[2] + min(side-1, max(0, x)) * strides[3]) }
        var binary = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let fx = (rect.minX + (Double(x)+0.5)/Double(w)*rect.width)*grid-0.5
            let fy = (rect.minY + (Double(y)+0.5)/Double(h)*rect.height)*grid-0.5
            let x0 = Int(floor(fx)), y0 = Int(floor(fy)), dx = fx-Double(x0), dy = fy-Double(y0)
            let top = logit(x0, y0)*(1-dx) + logit(x0+1, y0)*dx
            let bottom = logit(x0, y0+1)*(1-dx) + logit(x0+1, y0+1)*dx
            binary[y*w+x] = top*(1-dy) + bottom*dy > 0 ? 255 : 0
        } }
        guard binary.contains(255) else { return nil }
        return BallMask(rect: rect, width: w, height: h, alpha: BallMask.featheredCoverage(binary, width: w, height: h))
    }
}
