#if DEBUG
import CoreGraphics
import Foundation

/// Finds the board's four corner dots in the camera by blinking them.
///
/// The projector shows the dots, then hides them, a few times, while the camera
/// keeps small luma thumbnails. Averaging the frames from each phase and taking
/// the difference cancels everything that did not change (the wall, the boxes,
/// room light), leaving only the four dots. Only frames well inside each phase
/// are used, so screen-mirroring delay does not mix the phases.
nonisolated enum WallCornerFinder {
    static let width = 320, height = 180

    struct Frame: Sendable {
        let t: Double
        let luma: [UInt8]
    }

    /// A BGRA buffer sampled down to a `width` x `height` luma grid.
    static func thumbnail(_ base: UnsafePointer<UInt8>, width w: Int, height h: Int, rowBytes: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base + ((y * h + h / 2) / height) * rowBytes
            for x in 0..<width {
                let p = row + ((x * w + w / 2) / width) * 4
                out[y * width + x] = UInt8((Int(p[0]) * 29 + Int(p[1]) * 150 + Int(p[2]) * 77) >> 8)
            }
        }
        return out
    }

    /// Corners TL, TR, BR, BL normalised to the frame, or nil without four clear dots.
    static func corners(in frames: [Frame], on: [ClosedRange<Double>], off: [ClosedRange<Double>]) -> [CGPoint]? {
        guard !on.isEmpty, on.count == off.count else { return nil }
        var passes: [[CGPoint]] = []
        for (litSpan, darkSpan) in zip(on, off) {
            guard let lit = average(frames, in: [litSpan]), let dark = average(frames, in: [darkSpan]),
                  let points = find(lit: lit, dark: dark) else { return nil }
            passes.append(points)
        }
        // Pooling the two blinks can hide movement or a missing marker in one
        // pass. Every pass must independently observe the same four dots.
        let first = passes[0]
        guard passes.allSatisfy({ points in zip(first, points).allSatisfy {
            hypot(($0.x - $1.x) * Double(width), ($0.y - $1.y) * Double(height)) <= 2
        } }) else { return nil }
        return (0..<4).map { i in CGPoint(
            x: passes.reduce(0) { $0 + $1[i].x } / Double(passes.count),
            y: passes.reduce(0) { $0 + $1[i].y } / Double(passes.count)) }
    }

    private static func find(lit: [Double], dark: [Double]) -> [CGPoint]? {
        let diff = zip(lit, dark).map { max(0, $0 - $1) }
        let peak = diff.max() ?? 0
        guard peak >= 20 else { return nil }
        // In recorded bright-room attempts the left markers change by only
        // 9–12 luma levels, while scene noise is about one level. A fixed floor
        // of 12 discards them, even when lowering the peak-relative threshold.
        // Start above measured scene noise to retain each whole dot, rather
        // than centring on a few unstable pixels at the tip of its brightness.
        let floor = WallBlinkContrast.threshold(lit: lit, dark: dark)
        for threshold in [floor, max(floor, peak * 0.25), max(floor, peak * 0.4)] {
            if let points = components(diff, threshold: threshold) { return points }
        }
        return nil
    }

    private static func components(_ diff: [Double], threshold: Double) -> [CGPoint]? {
        var labelled = [Bool](repeating: false, count: diff.count)
        var blobs: [(weight: Double, x: Double, y: Double)] = []
        for start in diff.indices where diff[start] >= threshold && !labelled[start] {
            var stack = [start]
            labelled[start] = true
            var weight = 0.0, sx = 0.0, sy = 0.0, count = 0
            var clipped = false
            while let i = stack.popLast() {
                count += 1
                let x = i % width, y = i / width, v = diff[i]
                if x == 0 || x == width - 1 || y == 0 || y == height - 1 { clipped = true }
                weight += v; sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let j = ny * width + nx
                    if !labelled[j] && diff[j] >= threshold { labelled[j] = true; stack.append(j) }
                }
            }
            if count >= 3, !clipped { blobs.append((weight, sx / weight, sy / weight)) }
        }
        let ranked = blobs.sorted { $0.weight > $1.weight }
        guard ranked.count >= 4 else { return nil }
        // The fourth dot must stand clearly above anything else that changed.
        if ranked.count > 4, ranked[3].weight < 2 * ranked[4].weight { return nil }
        let points = ranked.prefix(4).map { CGPoint(x: $0.x / Double(width), y: $0.y / Double(height)) }
        let ordered = [points.min { $0.x + $0.y < $1.x + $1.y }!, points.max { $0.x - $0.y < $1.x - $1.y }!,
                       points.max { $0.x + $0.y < $1.x + $1.y }!, points.min { $0.x - $0.y < $1.x - $1.y }!]
        guard WallBoard.validCalibration(ordered) else { return nil }
        return ordered
    }

    static func average(_ frames: [Frame], in ranges: [ClosedRange<Double>]) -> [Double]? {
        let chosen = frames.filter { f in ranges.contains { $0.contains(f.t) } }
        guard chosen.count >= 3, let first = chosen.first,
              chosen.allSatisfy({ $0.luma.count == width * height }) else { return nil }
        var sum = [Double](repeating: 0, count: first.luma.count)
        for f in chosen { for i in sum.indices { sum[i] += Double(f.luma[i]) } }
        return sum.map { $0 / Double(chosen.count) }
    }

}

/// Averaged blink differences have a different noise scale from single camera
/// frames. Share the measured floor across outer-corner and interior-point
/// checks so uneven projection cannot pass one stage and fail the next solely
/// because one stage still uses a fixed global brightness cutoff.
nonisolated enum WallBlinkContrast {
    static func threshold(lit: [Double], dark: [Double]) -> Double {
        guard !lit.isEmpty, lit.count == dark.count else { return .infinity }
        let residuals = zip(lit, dark).map { abs($0 - $1) }.sorted()
        let noise = residuals[Int(Double(residuals.count - 1) * 0.9)]
        return max(6, 3 * noise)
    }
}
#endif
