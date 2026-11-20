#if DEBUG
import CoreGraphics
import CoreVideo
import Foundation

/// Short-lived, measured image matches between RF observations. Velocity only
/// places the search window; it never supplies a ball or a contact coordinate.
/// A failed/ambiguous match ends the track until the ball model seeds it again.
nonisolated struct WallBallPixelTracker {
    static let policy = "cpu-buffered-pixel-bridges-v4"
    static let maximumSeedAge = 0.18
    static let maximumFrameGap = 0.075
    struct Image {
        let luma: [UInt8]
        let width, height: Int
        let size: CGSize

        init(luma: [UInt8], width: Int, height: Int, size: CGSize) {
            self.luma = luma; self.width = width; self.height = height; self.size = size
        }
        init?(_ pixels: CVPixelBuffer) {
            guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
            size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            width = min(640, Int(size.width)); height = max(1, Int(size.height / size.width * Double(width)))
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
            var values = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height { for x in 0..<width {
                let sy = min(Int(size.height) - 1, Int((Double(y) + 0.5) * size.height / Double(height)))
                let sx = min(Int(size.width) - 1, Int((Double(x) + 0.5) * size.width / Double(width)))
                let i = sy * stride + sx * 4
                values[y * width + x] = UInt8((Int(bytes[i]) + 2 * Int(bytes[i + 1]) + Int(bytes[i + 2])) / 4)
            } }
            luma = values
        }
    }
    private struct Sample { let t: Double; let rect: CGRect }
    private var previous: Sample?
    private var latest: Sample?
    private var seedTime = -Double.infinity
    private var seedDiameter = 0.0
    private var size = CGSize.zero
    private var template: [Double] = []
    private(set) var failure: String?
    private(set) var matchScore = 0.0
    private(set) var rivalScore = 0.0
    var hasSeed: Bool { latest != nil && !template.isEmpty }

    static func agrees(_ tracked: Detection?, model: Detection?, size: CGSize) -> Bool {
        guard let tracked, let model, model.score >= 0.20 else { return false }
        let d = (model.width * size.width + model.height * size.height) / 2
        let td = (tracked.width * size.width + tracked.height * size.height) / 2
        return d > 0 && (0.85...1.18).contains(td / d)
            && hypot((model.x - tracked.x) * size.width, (model.y - tracked.y) * size.height) <= d * 0.30
    }

    mutating func reset() {
        previous = nil; latest = nil; template = []; seedTime = -.infinity; size = .zero
    }

    mutating func seed(_ ball: Detection, image: Image, at t: Double) {
        guard ball.score >= 0.20, t.isFinite else { return }
        let rect = CGRect(x: (ball.x - ball.width / 2) * Double(image.width),
                          y: (ball.y - ball.height / 2) * Double(image.height),
                          width: ball.width * Double(image.width), height: ball.height * Double(image.height))
        guard rect.width >= 5, rect.height >= 5, (0.65...1.55).contains(rect.width / rect.height),
              let patch = Self.patch(image, rect), Self.energy(patch) >= 16 else { reset(); return }
        if size != image.size || latest.map({ t < $0.t || t - $0.t > Self.maximumFrameGap }) == true { reset() }
        // A fresh RF result may refine the pixel match at this exact timestamp.
        // Preserve the preceding frame's velocity, not a zero-duration edge.
        if latest?.t != t { previous = latest }
        latest = Sample(t: t, rect: rect)
        seedTime = t; seedDiameter = (rect.width + rect.height) / 2
        template = Self.standardised(patch); size = image.size; failure = nil
    }

    mutating func update(_ image: Image, at t: Double) -> Detection? {
        guard let last = latest, size == image.size, t > last.t, t - last.t <= Self.maximumFrameGap,
              t - seedTime <= Self.maximumSeedAge, !template.isEmpty else {
            reset(); failure = "expired_or_unseeded"; return nil
        }
        let dt = t - last.t, d = (last.rect.width + last.rect.height) / 2
        var dx = 0.0, dy = 0.0
        if let previous, last.t > previous.t, last.t - previous.t <= Self.maximumFrameGap {
            dx = (last.rect.midX - previous.rect.midX) * dt / (last.t - previous.t)
            dy = (last.rect.midY - previous.rect.midY) * dt / (last.t - previous.t)
        }
        // Always include the last measured position: the wall reverses velocity.
        let radius = min(70.0, max(14, d * 2 * dt / 0.1))
        dx = max(-radius, min(radius, dx)); dy = max(-radius, min(radius, dy))
        let centre = CGPoint(x: last.rect.midX + dx / 2, y: last.rect.midY + dy / 2)
        let rx = radius + abs(dx) / 2, ry = radius + abs(dy) / 2
        let span = min(0.38, max(0.12, dt * 3.2))
        let scales = [1 - span, 1 - span / 2, 1.0, 1 + span / 2, 1 + span]
        var matches: [(score: Double, rect: CGRect)] = []
        for scale in scales {
            for y in stride(from: centre.y - ry, through: centre.y + ry, by: 4) {
                for x in stride(from: centre.x - rx, through: centre.x + rx, by: 4) {
                    let r = CGRect(x: x - last.rect.width * scale / 2, y: y - last.rect.height * scale / 2,
                                   width: last.rect.width * scale, height: last.rect.height * scale)
                    let score = Self.correlation(image, r, template)
                    if score >= 0.45 { matches.append((score, r)) }
                }
            }
        }
        guard var best = matches.max(by: { $0.score < $1.score }) else {
            reset(); failure = "no_match"; return nil
        }
        func refine(_ initial: (score: Double, rect: CGRect)) -> (score: Double, rect: CGRect) {
            var result = initial
            let coarse = initial.rect
            for scale in [0.94, 0.97, 1.0, 1.03, 1.06] {
                for y in stride(from: coarse.midY - 4, through: coarse.midY + 4, by: 1) {
                    for x in stride(from: coarse.midX - 4, through: coarse.midX + 4, by: 1) {
                        let r = CGRect(x: x - coarse.width * scale / 2, y: y - coarse.height * scale / 2,
                                       width: coarse.width * scale, height: coarse.height * scale)
                        let score = Self.correlation(image, r, template)
                        if score > result.score { result = (score, r) }
                    }
                }
            }
            return result
        }
        best = refine(best)
        let competitor = matches.filter { hypot($0.rect.midX - best.rect.midX, $0.rect.midY - best.rect.midY) > d * 0.65 }
            .max { $0.score < $1.score }
        // Compare equally refined peaks; a subpixel-aligned twin must not win
        // merely because the other identical object falls between coarse steps.
        let rival = competitor.map { $0.score > best.score - 0.25 ? refine($0).score : $0.score } ?? 0
        matchScore = best.score; rivalScore = rival
        let diameter = (best.rect.width + best.rect.height) / 2
        guard best.score >= 0.80, best.score - rival >= 0.10,
              (0.55...1.9).contains(diameter / seedDiameter),
              let patch = Self.patch(image, best.rect), Self.energy(patch) >= 16 else {
            reset(); failure = "weak_or_ambiguous"; return nil
        }
        previous = last; latest = Sample(t: t, rect: best.rect); template = Self.standardised(patch); failure = nil
        return Detection(score: best.score, x: best.rect.midX / Double(image.width), y: best.rect.midY / Double(image.height),
                         width: best.rect.width / Double(image.width), height: best.rect.height / Double(image.height))
    }

    // Include a thin border around the ball so size follows its silhouette as
    // well as the pattern. NCC tolerates changes in overall projector brightness.
    private static func patch(_ image: Image, _ rect: CGRect) -> [Double]? {
        let r = rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08)
        guard r.minX >= 0, r.minY >= 0, r.maxX < Double(image.width - 1), r.maxY < Double(image.height - 1),
              image.luma.count == image.width * image.height else { return nil }
        var values = [Double](); values.reserveCapacity(144)
        for y in 0..<12 { for x in 0..<12 {
            let px = r.minX + (Double(x) + 0.5) * r.width / 12, py = r.minY + (Double(y) + 0.5) * r.height / 12
            let ix = Int(px), iy = Int(py), fx = px - Double(ix), fy = py - Double(iy), i = iy * image.width + ix
            let a = Double(image.luma[i]) * (1 - fx) + Double(image.luma[i + 1]) * fx
            let b = Double(image.luma[i + image.width]) * (1 - fx) + Double(image.luma[i + image.width + 1]) * fx
            values.append(a * (1 - fy) + b * fy)
        } }
        return values
    }
    private static func energy(_ p: [Double]) -> Double {
        let mean = p.reduce(0, +) / Double(p.count)
        return p.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(p.count)
    }
    private static func standardised(_ values: [Double]) -> [Double] {
        let mean = values.reduce(0, +) / 144
        let norm = sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) })
        return values.map { ($0 - mean) / norm }
    }
    private static func correlation(_ image: Image, _ rect: CGRect, _ old: [Double]) -> Double {
        let r = rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08)
        guard r.minX >= 0, r.minY >= 0, r.maxX < Double(image.width - 1), r.maxY < Double(image.height - 1),
              image.luma.count == image.width * image.height else { return -1 }
        // The template is already zero-mean/unit-norm. Evaluate NCC without
        // allocating a patch for every search position on the iPhone CPU.
        return image.luma.withUnsafeBufferPointer { pixels in
            var sum = 0.0, squares = 0.0, dot = 0.0
            for y in 0..<12 {
                let py = r.minY + (Double(y) + 0.5) * r.height / 12
                let iy = Int(py), fy = py - Double(iy)
                for x in 0..<12 {
                    let px = r.minX + (Double(x) + 0.5) * r.width / 12
                    let ix = Int(px), fx = px - Double(ix), i = iy * image.width + ix
                    let a = Double(pixels[i]) * (1 - fx) + Double(pixels[i + 1]) * fx
                    let b = Double(pixels[i + image.width]) * (1 - fx) + Double(pixels[i + image.width + 1]) * fx
                    let v = a * (1 - fy) + b * fy
                    sum += v; squares += v * v; dot += old[y * 12 + x] * v
                }
            }
            let variance = squares - sum * sum / 144
            return variance >= 2304 ? dot / sqrt(variance) : -1
        }
    }
}
#endif
