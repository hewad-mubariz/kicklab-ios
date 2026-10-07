import CoreGraphics
import CoreVideo
import Foundation
import simd

/// A visible lower-leg boundary, not a reconstruction of a hidden sole. Only
/// components connected to the upper edge of the leg band can support the body;
/// detached balls and isolated mask noise must not pull the contact downward.
nonisolated struct VisibleFootContact: Sendable, Codable {
    var point: SIMD2<Float>
    var width: Float
    var confidence: Float = 1

    static func measure(person: CVPixelBuffer, rect: CGRect) -> Self? {
        guard CVPixelBufferGetPixelFormatType(person) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(person, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(person, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(person) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidth(person), h = CVPixelBufferGetHeight(person)
        let stride = CVPixelBufferGetBytesPerRow(person)
        let threshold: UInt8 = 64
        var top = h, bottom = -1
        for y in 0..<h {
            var count = 0
            for x in 0..<w where bytes[y * stride + x] >= threshold { count += 1 }
            if count >= max(3, w / 150) { top = min(top, y); bottom = y }
        }
        guard bottom - top > 12, bottom < h - 2 else { return nil }
        let band = top + Int(Double(bottom - top) * 0.62)
        var visited = [Bool](repeating: false, count: w * h)
        var candidates: [(x: Float, y: Float, width: Float)] = []
        // Seed only at the top of the band. A floating ball has no connection.
        for seedX in 0..<w where bytes[band * stride + seedX] >= threshold {
            let seed = band * w + seedX
            if visited[seed] { continue }
            var queue = [seed], head = 0
            var low = [Int](repeating: -1, count: w)
            visited[seed] = true
            while head < queue.count {
                let index = queue[head]; head += 1
                let x = index % w, y = index / w
                low[x] = max(low[x], y)
                for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] {
                    guard nx >= 0, nx < w, ny >= band, ny < h else { continue }
                    let next = ny * w + nx
                    if !visited[next], bytes[ny * stride + nx] >= threshold {
                        visited[next] = true; queue.append(next)
                    }
                }
            }
            guard queue.count >= max(8, (bottom - band) * 2), let lowest = low.max(), lowest > band + 3 else { continue }
            let tolerance = max(1, Int(Double(bottom - top) * 0.012))
            let xs = (0..<w).filter { low[$0] >= lowest - tolerance }
            guard xs.count >= 2, let first = xs.first, let last = xs.last else { continue }
            // Ground belongs at the bottom edge of the visible sole, not the
            // average of rows above it. Averaging buries the last few pixels.
            let y = Float(lowest + 1)
            candidates.append((Float(xs[xs.count/2]) + 0.5, y, Float(last-first+1)))
        }
        guard let foot = candidates.max(by: { $0.y < $1.y }) else { return nil }
        return Self(point: SIMD2(Float(rect.minX) + foot.x / Float(w) * Float(rect.width),
                                 Float(rect.minY) + foot.y / Float(h) * Float(rect.height)),
                    width: foot.width / Float(w) * Float(rect.width))
    }
}

/// Reject abrupt support changes when segmentation loses a lower leg. The
/// retained depth avoids a pop; confidence fades the shadow during uncertainty.
/// This is a stability filter, not a jump/contact classifier.
nonisolated struct FootContactTracker {
    private var current: VisibleFootContact?
    private var previousTime: Double?
    private var pending: VisibleFootContact?
    private var pendingCount = 0

    mutating func update(_ observed: VisibleFootContact?, at time: Double) -> VisibleFootContact? {
        guard time.isFinite else { return nil }
        let dt = previousTime.map { time - $0 } ?? 1.0/30
        if dt <= 0 || dt > 0.25 { current = nil; pending = nil; pendingCount = 0 }
        previousTime = time
        guard var prior = current else { current = observed; return current }
        guard let observed else {
            prior.confidence *= Float(exp(-max(0,dt)/0.08)); current = prior
            return current
        }
        let delta = abs(observed.point.y-prior.point.y)
        let limit = Float(max(0.018, min(0.035, dt*0.6)))
        if delta > limit {
            if let pending, abs(pending.point.y-observed.point.y) < 0.012 { pendingCount += 1 }
            else { pendingCount = 1 }
            pending = observed
            // A large upward jump can be a lost foot or an airborne player;
            // neither is sufficient evidence to move the floor to the knee.
            if pendingCount < 3 || delta > 0.08 {
                prior.confidence *= Float(exp(-max(0,dt)/0.08)); current = prior
                return current
            }
        }
        pending = nil; pendingCount = 0
        var result = observed
        let blend = Float(1-exp(-max(0,dt)/0.035))
        // An accepted visible boundary moving downward must not outrun a
        // lagging floor anchor. Upward motion still eases conservatively.
        result.point.y = max(observed.point.y,prior.point.y+(observed.point.y-prior.point.y)*blend)
        result.width = prior.width+(observed.width-prior.width)*blend
        current = result
        return result
    }
}
