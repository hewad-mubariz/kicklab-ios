import CoreImage
import CoreVideo
import Foundation
import Vision

/// Timestamped cutout in upright source coordinates. Rectangles use top-left UVs.
/// Keep person and ball masks separate until compositing: person segmentation
/// does not reliably include a football in flight.
nonisolated struct ForegroundMatte {
    let time: Double
    let person: CVPixelBuffer
    let personRect: CGRect
    let ball: CVPixelBuffer?
    let ballRect: CGRect?

    func image(size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let empty = CIImage(color: .black).cropped(to: bounds)
        func placed(_ buffer: CVPixelBuffer, _ rect: CGRect) -> CIImage {
            let raw = CIImage(cvPixelBuffer: buffer, options:[.colorSpace:NSNull()])
            return raw.transformed(by: CGAffineTransform(
                scaleX: rect.width * size.width / raw.extent.width,
                y: rect.height * size.height / raw.extent.height))
                .transformed(by: CGAffineTransform(translationX: rect.minX * size.width,
                    y: (1 - rect.maxY) * size.height))
        }
        var result = placed(person, personRect).composited(over: empty)
        if let ball, let ballRect {
            result = placed(ball, ballRect).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: result])
        }
        return result.cropped(to: bounds)
    }
}

/// Baseline person-video worker retained for comparative studies. Each sequence
/// owns its Vision state. Deliberately not
/// called from MTKView.draw. The study harness benchmarks this before UI adoption.
nonisolated final class ForegroundMaskProcessor {
    enum Failure: LocalizedError {
        case missingMask, invalidFrame, allocation
        var errorDescription: String? {
            switch self {
            case .missingMask: "Vision did not return a foreground mask."
            case .invalidFrame: "Foreground processing needs an upright BGRA frame and a finite timestamp."
            case .allocation: "Cannot allocate the foreground crop."
            }
        }
    }
    let quality: VNGeneratePersonSegmentationRequest.QualityLevel
    let sourceCrop: CGRect
    private let context: CIContext
    private var request: VNGeneratePersonSegmentationRequest
    private var cropBuffer: CVPixelBuffer?
    private var previousTime: Double?

    init(quality: VNGeneratePersonSegmentationRequest.QualityLevel, sourceCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), context: CIContext) {
        self.quality = quality; self.context = context
        let clipped = sourceCrop.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        self.sourceCrop = clipped.isNull || clipped.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : clipped
        self.request = Self.makeRequest(quality)
    }

    private static func makeRequest(_ quality: VNGeneratePersonSegmentationRequest.QualityLevel) -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.revision = VNGeneratePersonSegmentationRequestRevision1
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    func process(_ source: CVPixelBuffer, at time: Double, ball: CGRect?) throws -> ForegroundMatte {
        guard time.isFinite, CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { throw Failure.invalidFrame }
        if let previousTime, time <= previousTime || time - previousTime > 0.25 { request = Self.makeRequest(quality) }
        previousTime = time
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let crop = CGRect(x: sourceCrop.minX * CGFloat(width), y: sourceCrop.minY * CGFloat(height),
            width: sourceCrop.width * CGFloat(width), height: sourceCrop.height * CGFloat(height)).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let actualRect = CGRect(x: crop.minX / CGFloat(width), y: crop.minY / CGFloat(height),
            width: crop.width / CGFloat(width), height: crop.height / CGFloat(height))
        let input: CVPixelBuffer
        if actualRect == CGRect(x: 0, y: 0, width: 1, height: 1) { input = source }
        else {
            if cropBuffer == nil || CVPixelBufferGetWidth(cropBuffer!) != Int(crop.width) || CVPixelBufferGetHeight(cropBuffer!) != Int(crop.height) {
                cropBuffer = try Self.buffer(width: Int(crop.width), height: Int(crop.height), format: kCVPixelFormatType_32BGRA)
            }
            guard let cropBuffer else { throw Failure.allocation }
            let ciRect = CGRect(x: crop.minX, y: CGFloat(height) - crop.maxY, width: crop.width, height: crop.height)
            let image = CIImage(cvPixelBuffer: source).cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            context.render(image, to: cropBuffer)
            input = cropBuffer
        }
        try VNImageRequestHandler(cvPixelBuffer: input, orientation: .up, options: [:]).perform([request])
        guard let mask = request.results?.first?.pixelBuffer else { throw Failure.missingMask }
        let detail = try ball.flatMap { try BallForegroundMask.make(source: source, bounds: $0) }
        return ForegroundMatte(time: time, person: mask, personRect: actualRect, ball: detail?.pixels, ballRect: detail?.rect)
    }

    static func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard width > 0, height > 0,
              CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                &buffer) == kCVReturnSuccess, let buffer else { throw Failure.allocation }
        return buffer
    }
}
