#if DEBUG
import CoreGraphics
import Foundation

/// An independent check of the four-corner map, not a fit to those same corners.
/// Fifteen projected points cover the six target centres and internal dividers.
/// Two separate blink pairs must agree. No ball or inferred contact is involved.
nonisolated enum WallMappingCheck {
    static let width = 640, height = 360
    static let points = [0.5, 1.0, 1.5].flatMap { v in
        [0.5, 1.0, 1.5, 2.0, 2.5].map { CGPoint(x: $0, y: v) }
    }
    /// Initial engineering limit at the sampled points, in fractions of a cell.
    /// This is not a centimetre guarantee or an estimate of ball-contact error.
    static let limit = 0.05

    struct Frame: Sendable { let t: Double; let luma: [UInt8] }
    enum Status: String, Codable, Sendable {
        case passed, missingPoints, ambiguousPoints, misaligned, unstable, invalidGeometry
    }
    struct Sample: Codable, Equatable, Sendable {
        let pass, point: Int
        let u, v, observedX, observedY, errorPixels, errorCells: Double
    }
    struct Report: Codable, Equatable, Sendable {
        let status: Status
        let cornersNormalised: [[Double]]
        let frameWidth, frameHeight: Double
        let samples: [Sample]
        let limitCells: Double
        var passed: Bool { status == .passed }
        var maximumErrorPixels: Double? { samples.map(\.errorPixels).max() }
        var maximumErrorCells: Double? { samples.map(\.errorCells).max() }
    }

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

    static func check(_ frames: [Frame], on: [ClosedRange<Double>], off: [ClosedRange<Double>],
                      corners: [CGPoint], size: CGSize) -> Report {
        var samples: [Sample] = []
        func report(_ status: Status) -> Report {
            Report(status: status, cornersNormalised: corners.map { [Double($0.x), Double($0.y)] },
                   frameWidth: size.width, frameHeight: size.height, samples: samples, limitCells: limit)
        }
        guard WallBoard.validCalibration(corners), size.width > 0, size.height > 0,
              let board = WallBoard(topLeft: corners[0], topRight: corners[1],
                                    bottomRight: corners[2], bottomLeft: corners[3]) else { return report(.invalidGeometry) }
        guard on.count == 2, off.count == 2 else { return report(.missingPoints) }
        for pass in 0..<2 {
            guard let lit = average(frames, in: on[pass]), let dark = average(frames, in: off[pass]) else {
                return report(.missingPoints)
            }
            let blobs = components(zip(lit, dark).map { max(0, $0 - $1) })
            let mapped = blobs.map { board.boardPoint($0) }
            for (index, target) in points.enumerated() {
                // One isolated observed blob per target; never substitute its predicted position.
                let matches = mapped.indices.filter {
                    abs(mapped[$0].x - target.x) < 0.24 && abs(mapped[$0].y - target.y) < 0.24
                }
                guard let match = matches.first else { return report(.missingPoints) }
                guard matches.count == 1 else { return report(.ambiguousPoints) }
                let seen = blobs[match], expected = board.imagePoint(u: target.x, v: target.y)
                samples.append(Sample(pass: pass, point: index, u: target.x, v: target.y,
                    observedX: seen.x, observedY: seen.y,
                    errorPixels: hypot((seen.x - expected.x) * size.width, (seen.y - expected.y) * size.height),
                    errorCells: max(abs(mapped[match].x - target.x), abs(mapped[match].y - target.y))))
            }
        }
        for index in points.indices {
            let a = samples[index], b = samples[index + points.count]
            if hypot((a.observedX - b.observedX) * size.width,
                     (a.observedY - b.observedY) * size.height) > WallBoardAlignment.tolerancePixels {
                return report(.unstable)
            }
        }
        return report(samples.allSatisfy { $0.errorCells <= limit } ? .passed : .misaligned)
    }

    private static func average(_ frames: [Frame], in range: ClosedRange<Double>) -> [Double]? {
        let chosen = frames.filter { range.contains($0.t) }
        guard chosen.count >= 3, chosen.allSatisfy({ $0.luma.count == width * height }) else { return nil }
        var sum = [Double](repeating: 0, count: width * height)
        for frame in chosen { for i in sum.indices { sum[i] += Double(frame.luma[i]) } }
        return sum.map { $0 / Double(chosen.count) }
    }

    private static func components(_ diff: [Double]) -> [CGPoint] {
        let peak = diff.max() ?? 0
        guard peak >= 20 else { return [] }
        let threshold = max(12, peak * 0.4)
        var visited = [Bool](repeating: false, count: diff.count)
        var result: [CGPoint] = []
        for start in diff.indices where !visited[start] && diff[start] >= threshold {
            var stack = [start], count = 0
            var weight = 0.0, sx = 0.0, sy = 0.0
            visited[start] = true
            while let i = stack.popLast() {
                let x = i % width, y = i / width, value = diff[i]
                count += 1; weight += value
                sx += value * (Double(x) + 0.5); sy += value * (Double(y) + 0.5)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let j = ny * width + nx
                    if !visited[j] && diff[j] >= threshold { visited[j] = true; stack.append(j) }
                }
            }
            if count >= 3 { result.append(CGPoint(x: sx / weight / Double(width), y: sy / weight / Double(height))) }
        }
        return result
    }
}
#endif
