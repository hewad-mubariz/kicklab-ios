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

/// Exposure read from the real ball when its rim gives no measurement. Motion blur removes detail
/// along the motion and leaves it across, whatever the ball's design or distance, so the ratio of the
/// two on the fastest frames gives the blur length. The clip's own slowest frames, blurred here by known
/// lengths, say what each ratio means for this ball. Scalars and a few patches survive a frame.
nonisolated struct BallExposureEstimator {
    private static let referenceCount = 12
    private static let minimumObservations = 60
    /// Slower than this at the clip's fastest, in 720p pixels per second, blur cannot show.
    private static let minimumSpeed = 200.0
    private static let lengths: [Double] = [0, 1, 2, 3, 4, 6, 8, 10, 13, 16, 20]

    private let frameDuration: Double
    private var observations: [(speed: Double, along: Double, pixelsPerPatch: Double)] = []
    private var references: [(speed: Double, time: Double, patch: BallSurfaceMotion.Gray)] = []

    init(frameDuration: Double) { self.frameDuration = frameDuration }

    mutating func observe(time: Double, velocity: CGVector, patch: BallSurfaceMotion.Gray, radius: Double) {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed.isFinite, speed > 0, time.isFinite, radius > 0 else { return }
        let ux = velocity.dx / speed, uy = velocity.dy / speed
        if let along = Self.ratio(patch, ux: ux, uy: uy) {
            observations.append((speed, along, radius / BallSurfaceMotion.radius))
        }
        // Keep the slowest frames, at most one from any moment: neighbours add no information.
        if let near = references.firstIndex(where: { abs($0.time - time) < 0.1 }) {
            if speed < references[near].speed { references[near] = (speed, time, patch) }
        } else if references.count < Self.referenceCount {
            references.append((speed, time, patch))
        } else if let slowest = references.indices.max(by: { references[$0].speed < references[$1].speed }),
                  speed < references[slowest].speed {
            references[slowest] = (speed, time, patch)
        }
    }

    /// Seconds. Zero when the real ball shows no blur; nil without enough frames to say.
    var estimate: Double? {
        guard observations.count >= Self.minimumObservations, !references.isEmpty,
              frameDuration.isFinite, frameDuration > 0 else { return nil }
        let sorted = observations.sorted { $0.speed < $1.speed }
        let fast = sorted.suffix(max(10, sorted.count / 20))
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let speed = median(fast.map(\.speed))
        guard speed >= Self.minimumSpeed else { return 0 }
        let blur = length(forRatio: median(fast.map(\.along))) * median(fast.map(\.pixelsPerPatch))
        return min(blur / speed, 0.9 * frameDuration)
    }

    private func length(forRatio value: Double) -> Double {
        let curve = Self.lengths.map { length -> Double in
            let logs = references.enumerated().compactMap { index, reference -> Double? in
                let angle = Double(index % 4) * .pi / 4 + 0.2
                return Self.ratio(reference.patch, ux: cos(angle), uy: sin(angle), blur: length).flatMap { $0 > 0 ? log($0) : nil }
            }.sorted()
            return logs.isEmpty ? 1 : exp(logs[logs.count / 2])
        }
        // Relative to the sharp end, so a ball that reads slightly off 1.0 when sharp still reads zero.
        let target = value / max(curve[0], 1e-6)
        for i in 1..<curve.count {
            let a = curve[i - 1] / curve[0], b = curve[i] / curve[0]
            if target >= a { return Self.lengths[i - 1] }
            if target >= b { return Self.lengths[i - 1] + (a - target) / max(a - b, 1e-6) * (Self.lengths[i] - Self.lengths[i - 1]) }
        }
        return Self.lengths[Self.lengths.count - 1]
    }

    /// Gradient energy along (ux, uy) over energy across it, inside the ball, after an optional blur along it.
    private static func ratio(_ patch: BallSurfaceMotion.Gray, ux: Double, uy: Double, blur: Double = 0) -> Double? {
        let reach = BallSurfaceMotion.radius * 0.72, center = BallSurfaceMotion.center
        let low = max(1, Int(center - reach)), high = min(patch.width - 2, Int(center + reach) + 1)
        guard high > low else { return nil }
        let steps = max(1, Int(blur.rounded(.up)))
        func value(_ x: Int, _ y: Int) -> Double {
            guard blur > 0 else { return Double(patch.values[y * patch.width + x]) }
            var sum = 0.0
            for k in 0..<steps {
                let t = ((Double(k) + 0.5) / Double(steps) - 0.5) * blur
                sum += patch.at(Double(x) + ux * t, Double(y) + uy * t)
            }
            return sum / Double(steps)
        }
        var along = 0.0, across = 0.0
        for y in low...high { for x in low...high {
            let dx = Double(x) - center, dy = Double(y) - center
            guard dx * dx + dy * dy <= reach * reach else { continue }
            let gx = value(x + 1, y) - value(x - 1, y), gy = value(x, y + 1) - value(x, y - 1)
            let a = ux * gx + uy * gy, b = ux * gy - uy * gx
            along += a * a; across += b * b
        } }
        return across > 0 ? along / across : nil
    }
}
