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
        guard let lit = average(frames, in: on), let dark = average(frames, in: off) else { return nil }
        let diff = zip(lit, dark).map { max(0, $0 - $1) }
        let peak = diff.max() ?? 0
        guard peak >= 20 else { return nil }
        let threshold = max(12, peak * 0.4)

        var labelled = [Bool](repeating: false, count: diff.count)
        var blobs: [(weight: Double, x: Double, y: Double)] = []
        for start in diff.indices where diff[start] >= threshold && !labelled[start] {
            var stack = [start]
            labelled[start] = true
            var weight = 0.0, sx = 0.0, sy = 0.0
            while let i = stack.popLast() {
                let x = i % width, y = i / width, v = diff[i]
                weight += v; sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let j = ny * width + nx
                    if !labelled[j] && diff[j] >= threshold { labelled[j] = true; stack.append(j) }
                }
            }
            blobs.append((weight, sx / weight, sy / weight))
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

    private static func average(_ frames: [Frame], in ranges: [ClosedRange<Double>]) -> [Double]? {
        let chosen = frames.filter { f in ranges.contains { $0.contains(f.t) } }
        guard chosen.count >= 3, let first = chosen.first,
              chosen.allSatisfy({ $0.luma.count == width * height }) else { return nil }
        var sum = [Double](repeating: 0, count: first.luma.count)
        for f in chosen { for i in sum.indices { sum[i] += Double(f.luma[i]) } }
        return sum.map { $0 / Double(chosen.count) }
    }

    /// Shoelace area of a quad in normalised units.
    private static func area(_ p: [CGPoint]) -> Double {
        abs((0..<4).reduce(0.0) { $0 + p[$1].x * p[($1 + 1) % 4].y - p[($1 + 1) % 4].x * p[$1].y }) / 2
    }
}
#endif
