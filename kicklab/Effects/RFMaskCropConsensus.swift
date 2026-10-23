import CoreGraphics
import Foundation

/// Appearance evidence only. A high object score does not establish a complete
/// outline. Require two current-exposure contexts to agree before changing it.
nonisolated enum RFMaskCropConsensus {
    static let contexts = [3.5, 4.5, 2.5]

    struct Candidate {
        let ball: Detection
        let mask: BallMask
    }

    static func candidate(_ result: FrameDetections, guide: RecordedFrame,
                          roi: CGRect, size: CGSize) -> Candidate? {
        guard let b = result.ball, b.score >= 0.9, let raw = result.ballMask,
              [b.x, b.y, b.width, b.height, b.score, guide.width, guide.height].allSatisfy(\.isFinite),
              b.width > 0, b.height > 0, guide.width > 0, guide.height > 0,
              raw.width > 1, raw.height > 1, raw.alpha.count == raw.width * raw.height else { return nil }
        let shift = hypot((b.x - guide.x) / guide.width, (b.y - guide.y) / guide.height)
        guard shift < 0.45, (0.65...1.4).contains(b.width / guide.width),
              (0.65...1.4).contains(b.height / guide.height) else { return nil }
        let box = CGRect(x: (b.x - b.width / 2) * size.width, y: (b.y - b.height / 2) * size.height,
                         width: b.width * size.width, height: b.height * size.height)
        // A source-frame crop is real; an artificial ROI edge is not an outline.
        guard (roi.minX == 0 || box.minX > roi.minX + 2),
              (roi.minY == 0 || box.minY > roi.minY + 2),
              (roi.maxX == size.width || box.maxX < roi.maxX - 2),
              (roi.maxY == size.height || box.maxY < roi.maxY - 2) else { return nil }
        return Candidate(ball: b, mask: raw.expanded())
    }

    static func agreement(_ a: Candidate, _ b: Candidate, guide: RecordedFrame) -> Double? {
        let shift = hypot((a.ball.x - b.ball.x) / guide.width, (a.ball.y - b.ball.y) / guide.height)
        guard shift < 0.12, abs(log(a.ball.width / b.ball.width)) < 0.15,
              abs(log(a.ball.height / b.ball.height)) < 0.15 else { return nil }
        let rect = a.mask.rect.union(b.mask.rect)
        var overlap = 0.0, union = 0.0
        for y in 0..<96 { for x in 0..<96 {
            let px = rect.minX + (Double(x) + 0.5) * rect.width / 96
            let py = rect.minY + (Double(y) + 0.5) * rect.height / 96
            let av = a.mask.coverage(x: px, y: py), bv = b.mask.coverage(x: px, y: py)
            overlap += min(av, bv); union += max(av, bv)
        } }
        guard union > 0, overlap / union >= 0.90 else { return nil }
        return overlap / union
    }

    static func accepted(_ candidates: [Candidate], guide: RecordedFrame) -> BallMask? {
        var best: (Candidate, Candidate, Double)?
        for i in candidates.indices { for j in candidates.indices where j > i {
            guard let score = agreement(candidates[i], candidates[j], guide: guide),
                  score > (best?.2 ?? 0) else { continue }
            best = (candidates[i], candidates[j], score)
        } }
        guard let (a, b, _) = best else { return nil }
        return fused(a.mask, b.mask, old: guide.ballMask?.expanded()).compacted()
    }

    /// Preserve the established one-call repair for modest additions. Changes
    /// outside these bounds, including removing false ownership, need consensus.
    static func conservativeAddition(_ candidate: Candidate, guide: RecordedFrame) -> BallMask? {
        let mask = candidate.mask, b = candidate.ball
        let candidateArea = RFMaskCropRefiner.area(mask)
        guard (0.48...1.05).contains(candidateArea / (b.width * b.height)) else { return nil }
        if let old = guide.ballMask?.expanded() {
            let oldArea = RFMaskCropRefiner.area(old)
            guard candidateArea >= oldArea * 1.02, candidateArea <= oldArea * 1.45 else { return nil }
            var support = 0.0, retained = 0.0
            for y in 0..<32 { for x in 0..<32 {
                let px = old.rect.minX + (Double(x) + 0.5) / 32 * old.rect.width
                let py = old.rect.minY + (Double(y) + 0.5) / 32 * old.rect.height
                let a = old.coverage(x: px, y: py)
                support += a; retained += min(a, mask.coverage(x: px, y: py))
            } }
            guard support > 0, retained / support >= 0.9 else { return nil }
        }
        return mask.compacted()
    }

    private static func fused(_ a: BallMask, _ b: BallMask, old: BallMask?) -> BallMask {
        let rect = a.rect.union(b.rect).union(old?.rect ?? a.rect), w = 128, h = 128
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let px = rect.minX + (Double(x) + 0.5) * rect.width / Double(w)
            let py = rect.minY + (Double(y) + 0.5) * rect.height / Double(h)
            let av = a.coverage(x: px, y: py), bv = b.coverage(x: px, y: py)
            let ov = old?.coverage(x: px, y: py) ?? 0
            // Both contexts must support adding or removing ownership. This can
            // recover a missing white panel AND remove a wrongly included finger.
            let value: Double
            if av >= ov && bv >= ov { value = min(av, bv) }
            else if av <= ov && bv <= ov { value = max(av, bv) }
            else { value = ov }
            alpha[y * w + x] = UInt8((max(0, min(1, value)) * 255).rounded())
        } }
        // The grid above stores the fused result; it does not define the original
        // decoder's dilation. Preserve the coarser of the two agreeing contexts.
        let step = CGSize(width: max(a.samplingSize.width, b.samplingSize.width),
                          height: max(a.samplingSize.height, b.samplingSize.height))
        return BallMask(rect: rect, width: w, height: h, alpha: alpha, decoderPixelSize: step)
    }
}
