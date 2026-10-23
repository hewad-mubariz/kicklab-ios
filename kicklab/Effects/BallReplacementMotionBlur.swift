import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Measures a straight motion-blurred edge in the current photograph. The track
/// supplies direction, not proof of blur. Opposite sides must agree before the
/// measurement can replace the track's clip-wide estimate.
nonisolated enum BallReplacementMotionBlur {
    static func measured(pixels: CVPixelBuffer, body: BallReplacementFootprint,
                         suggested: CGVector) -> CGVector? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return measured(bytes: bytes, stride: CVPixelBufferGetBytesPerRow(pixels),
            width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
            origin: .zero, body: body, suggested: suggested)
    }

    private static func measured(bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int,
                                 origin: CGPoint, body: BallReplacementFootprint, suggested: CGVector) -> CGVector? {
        let scale = max(0.25, min(body.sourceSize.width, body.sourceSize.height) / 720)
        let prior = hypot(Double(suggested.dx), Double(suggested.dy))
        guard prior.isFinite, prior >= 2 * scale, body.radius >= 10 * scale else { return nil }
        let axis = SIMD2<Double>(Double(suggested.dx) / prior, Double(suggested.dy) / prior)
        let reach = min(body.radius * 0.6, 25 * scale)
        let offsets = (0...64).map { -reach + 2 * reach * Double($0) / 64 }
        var sides = [[Double](), [Double]()]
        func colour(_ point: SIMD2<Double>) -> SIMD3<Double>? {
            let x = point.x - origin.x, y = point.y - origin.y
            guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return nil }
            let ix = Int(x), iy = Int(y), fx = x - Double(ix), fy = y - Double(iy)
            func at(_ xx: Int, _ yy: Int) -> SIMD3<Double> {
                let p = bytes + yy * stride + xx * 4
                return SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
            }
            return (at(ix, iy) * (1 - fx) + at(ix + 1, iy) * fx) * (1 - fy)
                + (at(ix, iy + 1) * (1 - fx) + at(ix + 1, iy + 1) * fx) * fy
        }
        for ray in 0..<48 {
            let angle = Double(ray) * 2 * .pi / 48, normal = SIMD2(cos(angle), sin(angle))
            let signedAlignment = simd_dot(axis, normal), alignment = abs(signedAlignment)
            guard alignment >= 0.6 else { continue }
            let edge = body.edge(at: angle), center = SIMD2(Double(body.center.x), Double(body.center.y))
            let colours = offsets.compactMap { colour(center + normal * (edge + $0)) }
            guard colours.count == offsets.count else { continue }
            let foreground = colours.prefix(6).reduce(SIMD3<Double>.zero, +) / 6
            let background = colours.suffix(6).reduce(SIMD3<Double>.zero, +) / 6
            let delta = foreground - background, norm = simd_length_squared(delta)
            let variance = colours.suffix(6).reduce(SIMD3<Double>.zero) {
                $0 + ($1 - background) * ($1 - background)
            } / 6
            guard norm > 1200, max(variance.x, variance.y, variance.z) < 80 else { continue }
            let profile = colours.map { simd_dot($0 - background, delta) / norm }
            var residual = 0.0
            for i in colours.indices {
                residual += simd_length_squared(colours[i] - (background + delta * profile[i])) / 3
            }
            guard residual / Double(colours.count) < 100 else { continue }
            var bestError = 0.025, bestLength: Double?
            // This is one shared exposure length, projected onto each edge normal.
            // A fitted position only tolerates small contour error; it never moves
            // the ball, texture, or an occluding hand/foot.
            for lengthIndex in 0..<32 {
                let length = scale + (2 * reach - scale) * Double(lengthIndex) / 31
                for shiftIndex in 0..<13 {
                    let shift = body.radius * 0.13 * (Double(shiftIndex) / 6 - 1)
                    var error = 0.0
                    for i in offsets.indices {
                        let expected = min(1, max(0, 0.5 - (offsets[i] - shift) / (length * alignment)))
                        let d = profile[i] - expected
                        error += d * d
                    }
                    error /= Double(profile.count)
                    if error < bestError { bestError = error; bestLength = length }
                }
            }
            if let bestLength, bestLength < reach * 1.9 {
                sides[signedAlignment >= 0 ? 0 : 1].append(bestLength)
            }
        }
        guard sides.allSatisfy({ $0.count >= 3 }) else { return nil }
        let medians = sides.map { $0.sorted()[$0.count / 2] }
        guard abs(medians[0] - medians[1]) <= max(4 * scale, max(medians[0], medians[1]) * 0.35) else { return nil }
        let combined = (sides[0] + sides[1]).sorted()
        let length = combined[combined.count / 2]
        let deviations = combined.map { abs($0 - length) }.sorted()
        // Bilinear sampling and the photographed antialiased edge alone can
        // resemble a two-pixel ramp. That is not evidence of camera exposure.
        guard length >= 3 * scale,
              deviations[deviations.count / 2] <= max(3 * scale, length * 0.3),
              length.isFinite else { return nil }
        return CGVector(dx: axis.x * length, dy: axis.y * length)
    }
}

/// Bounded calibration during the existing source-spin pass. Only scalar
/// measurements survive a frame. This is a photographic estimate, never a
/// claim about the camera's actual shutter setting.
nonisolated struct BallExposureCalibration {
    private let interval: Double
    private let frameDuration: Double
    private var lastAttempt = -Double.infinity
    private var observations: [(time: Double, seconds: Double)] = []

    init(duration: Double, frameDuration: Double) {
        interval = max(0.08, duration / 480)
        self.frameDuration = frameDuration
    }

    mutating func shouldMeasure(at time: Double) -> Bool {
        guard time.isFinite, time - lastAttempt >= interval else { return false }
        lastAttempt = time
        return true
    }

    mutating func observe(time: Double, smear: CGVector, velocity: CGVector) {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed.isFinite, speed > 0 else { return }
        let seconds = hypot(smear.dx, smear.dy) / speed
        // A noisy individual edge may overestimate the frame's integration
        // interval. Reject gross outliers; constrain the final robust estimate.
        guard time.isFinite, seconds.isFinite, seconds > 0,
              frameDuration.isFinite, frameDuration > 0, seconds <= frameDuration * 1.5 else { return }
        observations.append((time, seconds))
    }

    var estimate: Double? {
        guard observations.count >= 8, let first = observations.first, let last = observations.last,
              last.time - first.time >= 1 else { return nil }
        let values = observations.map(\.seconds).sorted(), median = values[values.count / 2]
        let deviations = values.map { abs($0 - median) }.sorted()
        guard deviations[deviations.count / 2] <= median * 0.25,
              values.filter({ abs($0 - median) <= median * 0.4 }).count * 4 >= values.count * 3 else { return nil }
        return min(frameDuration, median)
    }
}
