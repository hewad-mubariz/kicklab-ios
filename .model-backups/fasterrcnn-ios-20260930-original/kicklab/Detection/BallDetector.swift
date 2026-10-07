//
//  BallDetector.swift
//  kicklab
//
//  CoreML detector. The model returns the answer; this file only feeds it pixels.
//
//  An earlier version exported the raw network - 3234 anchors of logits and box
//  deltas - and decoded them here. That code caused every device bug we hit:
//  assuming contiguous memory read padding and reported a ball in every frame at
//  a meaningless 0.500; `dataPointer` crashed with EXC_BAD_ACCESS on device but
//  not in the simulator; and two different capacity calculations silently
//  rejected every frame. Four attempts, four failures, all in arithmetic the
//  model can do itself.
//
//  So it does. Softmax, box decoding and the argmax now live inside the exported
//  graph (scripts/export_decoded.py), which is verified against PyTorch at export
//  time. What is left here is ten scalars read through the safe subscript.
//
//  Everything returned is normalised 0-1. The counter's thresholds are fractions
//  of the frame; handing it pixels would not fail loudly, it would count wrongly.
//

import CoreImage
import CoreML
import CoreVideo
import Foundation

nonisolated struct Detection {
    var score: Double
    /// Centre and size, normalised 0-1.
    var x, y, width, height: Double
}

nonisolated struct FrameDetections {
    var ball: Detection?
    var person: Detection?
}

final class BallDetector {
    /// Layout of the model's single output.
    private enum Slot {
        static let ballScore = 0, ballBox = 1
        static let personScore = 5, personBox = 6
        static let count = 10
    }

    /// SSD's anchors are generated for one fixed input size.
    private let side = 320

    /// Scores below this are not worth reporting.
    ///
    /// 0.05, far below a typical detector default, and deliberately so: this
    /// model's ball scores are calibrated low - the median correct detection sits
    /// near 0.27, and a 0.35 threshold threw away two thirds of a working model.
    /// Measured on held-out frames, 0.05 finds the ball in 97.5% of them with
    /// 94.3% of those in the right place.
    static let ballThreshold = 0.05
    static let personThreshold = 0.5

    private let model: MLModel
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var scratch: CVPixelBuffer?

    /// Size of the frame actually handed to the model, after any rotation.
    private(set) var lastInputSize: CGSize = .zero
    /// The exact buffer given to the model, when one was requested.
    private(set) var lastModelInput: CGImage?
    /// Set to request one snapshot of the model's input on the next frame.
    var wantsModelInputSnapshot = false
    /// Why the last frame produced nothing, when it produced nothing.
    private(set) var lastError: String?

    init() throws {
        guard let url = Bundle.main.url(forResource: "KickLabDetector", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "KickLabDetector", withExtension: "mlpackage") else {
            throw NSError(domain: "KickLab", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "KickLabDetector not in bundle"])
        }
        let configuration = MLModelConfiguration()
        // .all lets CoreML use the Neural Engine, which is where 30fps lives.
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    func detect(_ pixelBuffer: CVPixelBuffer, orientLandscapeAsPortrait: Bool = true) throws -> FrameDetections {
        let input = try makeInput(from: pixelBuffer, orientLandscapeAsPortrait: orientLandscapeAsPortrait)
        let out = try model.prediction(from: input)
        guard let result = out.featureValue(for: "detection")?.multiArrayValue else {
            lastError = "no 'detection' output"
            return FrameDetections(ball: nil, person: nil)
        }
        guard result.count >= Slot.count else {
            lastError = "detection has \(result.count) values, expected \(Slot.count)"
            return FrameDetections(ball: nil, person: nil)
        }
        lastError = nil

        // Ten reads through the subscript. It respects strides, bounds and
        // backing store by construction - the only access method that has ever
        // agreed with the lab.
        func value(_ i: Int) -> Double { Double(result[i].floatValue) }

        func detection(scoreAt s: Int, boxAt b: Int, threshold: Double) -> Detection? {
            let score = value(s)
            guard score >= threshold else { return nil }
            let d = Detection(score: score, x: value(b), y: value(b + 1),
                              width: value(b + 2), height: value(b + 3))
            // A large delta can overflow exp() to inf inside the model.
            guard d.x.isFinite, d.y.isFinite, d.width.isFinite, d.height.isFinite,
                  d.width > 0, d.height > 0 else { return nil }
            return d
        }

        return FrameDetections(
            ball: detection(scoreAt: Slot.ballScore, boxAt: Slot.ballBox,
                            threshold: Self.ballThreshold),
            person: detection(scoreAt: Slot.personScore, boxAt: Slot.personBox,
                              threshold: Self.personThreshold))
    }

    // MARK: - Input

    /// Camera frame to the 320x320 RGB float tensor the model expects.
    ///
    /// Normalisation happens inside the model, so this hands over plain 0-1.
    private func makeInput(from pixelBuffer: CVPixelBuffer, orientLandscapeAsPortrait: Bool) throws -> MLFeatureProvider {
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32)
        let resized = try square(pixelBuffer, orientLandscapeAsPortrait: orientLandscapeAsPortrait)
        CVPixelBufferLockBaseAddress(resized, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(resized, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(resized) else {
            throw NSError(domain: "KickLab", code: 3)
        }
        let stride = CVPixelBufferGetBytesPerRow(resized)
        let src = base.assumingMemoryBound(to: UInt8.self)
        // Safe here: this is a buffer we created, contiguous and CPU-backed.
        let dst = UnsafeMutablePointer<Float>(OpaquePointer(array.dataPointer))
        let plane = side * side

        // BGRA in, planar RGB out, scaled to 0-1.
        for y in 0..<side {
            let row = src + y * stride
            for x in 0..<side {
                let p = row + x * 4
                let i = y * side + x
                dst[i] = Float(p[2]) / 255.0
                dst[plane + i] = Float(p[1]) / 255.0
                dst[2 * plane + i] = Float(p[0]) / 255.0
            }
        }
        return try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(multiArray: array)])
    }

    /// Resize to the model's square input, rotating to portrait first.
    ///
    /// The aspect ratio is deliberately not preserved: torchvision pads to a
    /// square before the backbone, so the model has only ever seen squares.
    private func square(_ pixelBuffer: CVPixelBuffer, orientLandscapeAsPortrait: Bool) throws -> CVPixelBuffer {
        if scratch == nil {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &buffer)
            scratch = buffer
        }
        guard let out = scratch else { throw NSError(domain: "KickLab", code: 4) }
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // Rotate to portrait by inspecting the buffer, not by asking the capture
        // connection - that request can be silently declined, and the preview
        // layer rotates independently, so the screen can look upright while the
        // model is handed a sideways frame it has never seen.
        if orientLandscapeAsPortrait, image.extent.width > image.extent.height {
            image = image.oriented(.right)
        }
        // oriented() can leave a non-zero origin; scaling without moving it back
        // would render the frame offset, leaving stale pixels in the input.
        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }
        lastInputSize = CGSize(width: image.extent.width, height: image.extent.height)

        let sx = CGFloat(side) / image.extent.width
        let sy = CGFloat(side) / image.extent.height
        ciContext.render(image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: out)

        // Snapshotting costs a GPU->CPU readback; only when asked.
        if wantsModelInputSnapshot {
            lastModelInput = ciContext.createCGImage(
                CIImage(cvPixelBuffer: out),
                from: CGRect(x: 0, y: 0, width: side, height: side))
            wantsModelInputSnapshot = false
        }
        return out
    }
}
