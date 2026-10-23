import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Bounded current-frame background evidence for blurred outer edges. This does
/// not inpaint a hidden scene. It only extrapolates a locally uniform surround;
/// textured regions, frame edges and foreground cut-outs retain source-over.
nonisolated struct BallReplacementBackground {
    struct Estimate {
        /// BGRA byte-space colour, matching the material rasterizer.
        let colour: SIMD3<Double>
        let confidence: Double
    }
    private let matte: BallReplacementCoverage
    private let sectors: [Estimate?]
    private static let count = 96

    init?(pixels: CVPixelBuffer, matte: BallReplacementCoverage) {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        self.init(bytes: bytes, stride: CVPixelBufferGetBytesPerRow(pixels),
            width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), origin: .zero, matte: matte)
    }

    init?(image: CGImage, matte: BallReplacementCoverage) {
        let size = CGSize(width: image.width, height: image.height)
        let padding = min(size.width, size.height) / 720 * 28
        let rect = matte.bounds.insetBy(dx: -padding, dy: -padding).integral.intersection(CGRect(origin: .zero, size: size))
        guard !rect.isEmpty, let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        self.init(bytes: bytes, stride: context.bytesPerRow, width: crop.width, height: crop.height, origin: rect.origin, matte: matte)
    }

    private init?(bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int,
                  origin: CGPoint, matte: BallReplacementCoverage) {
        guard matte.reconstructsBody else { return nil }
        self.matte = matte
        let body = matte.footprint, scale = max(0.25, min(body.sourceSize.width, body.sourceSize.height) / 720)
        func colour(_ x: Double, _ y: Double) -> SIMD3<Double>? {
            let xx = Int((x - origin.x).rounded()), yy = Int((y - origin.y).rounded())
            guard xx >= 0, yy >= 0, xx < width, yy < height else { return nil }
            let p = bytes + yy * stride + xx * 4
            return SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
        }
        sectors = (0..<Self.count).map { index in
            let angle = Double(index) * 2 * .pi / Double(Self.count)
            var colors = [SIMD3<Double>]()
            // Adjacent angular and radial samples must agree. A single wall or
            // skin pixel is not evidence for what is behind a blurred boundary.
            for offset in [-1.0, 0, 1] {
                let a = angle + offset * min(0.08, 3 * scale / body.radius), c = cos(a), s = sin(a)
                var first: Double?
                for distance in Swift.stride(from: 0.0, through: 24 * scale, by: 1.5 * scale) {
                    let r = body.edge(at: a) + distance
                    let x = body.center.x + c * r, y = body.center.y + s * r
                    if matte.coverage(x: x, y: y) < 0.005 { first = r; break }
                }
                guard let first else { return nil }
                for extra in [3.0, 5, 7] {
                    let r = first + extra * scale
                    let x = body.center.x + c * r, y = body.center.y + s * r
                    guard matte.coverage(x: x, y: y) < 0.005, let value = colour(x, y) else { return nil }
                    colors.append(value)
                }
            }
            var low = colors[0], high = colors[0], sum = SIMD3<Double>(repeating: 0)
            for color in colors { low = simd_min(low, color); high = simd_max(high, color); sum += color }
            let difference = high - low, spread = max(difference.x, difference.y, difference.z)
            guard spread < 12 else { return nil }
            return Estimate(colour: sum / Double(colors.count), confidence: min(1, (12 - spread) / 6))
        }
    }

    func estimate(x: Double, y: Double) -> Estimate? {
        guard matte.allowsBackgroundEstimate(x: x, y: y) else { return nil }
        let center = matte.footprint.center
        let phase = (atan2(y - center.y, x - center.x) + 2 * .pi)
            .truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi) * Double(Self.count)
        let i = Int(phase) % Self.count, fraction = phase - floor(phase)
        guard let a = sectors[i], let b = sectors[(i + 1) % Self.count] else { return nil }
        let difference = simd_abs(a.colour - b.colour)
        guard max(difference.x, difference.y, difference.z) < 12 else { return nil }
        return Estimate(colour: a.colour * (1 - fraction) + b.colour * fraction,
                        confidence: min(a.confidence, b.confidence))
    }
}
