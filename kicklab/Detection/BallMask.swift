import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Small, owned appearance mask in upright source coordinates. Never retains a
/// model output, prototype tensor or camera buffer beyond the inference frame.
nonisolated struct BallMask: Sendable {
    let rect: CGRect
    let width: Int
    let height: Int
    let alpha: [UInt8]

    func coverage(x: Double, y: Double) -> Double {
        let u = (x - rect.minX) / rect.width * Double(width) - 0.5
        let v = (y - rect.minY) / rect.height * Double(height) - 0.5
        guard u >= 0, v >= 0, u < Double(width - 1), v < Double(height - 1) else { return 0 }
        let ix = Int(u), iy = Int(v), fx = u - Double(ix), fy = v - Double(iy)
        func a(_ x: Int, _ y: Int) -> Double { Double(alpha[y * width + x]) / 255 }
        return (a(ix, iy) * (1-fx) + a(ix+1, iy) * fx) * (1-fy)
            + (a(ix, iy+1) * (1-fx) + a(ix+1, iy+1) * fx) * fy
    }

    func footprint(in size: CGSize) -> BallReplacementFootprint {
        let radius = max(rect.width * size.width, rect.height * size.height) / 2
        return BallReplacementFootprint(sourceSize: size,
            center: CGPoint(x: rect.midX * size.width, y: rect.midY * size.height),
            radius: radius, radii: Array(repeating: radius, count: 64), feather: 1, padding: 0)
    }

    /// Decode only the selected ball. The box selection deliberately matches
    /// BallDetector.decodedValues, including source-content clipping and ties.
    static func decode(_ out: MLFeatureProvider, content: CGRect, sourceSize: CGSize,
                       threshold: Double, selectedIndex: Int? = nil, sourceBorder: Double = 0) -> BallMask? {
        guard let boxes = out.featureValue(for: "boxes")?.multiArrayValue,
              let scores = out.featureValue(for: "scores")?.multiArrayValue,
              let labels = out.featureValue(for: "labels")?.multiArrayValue,
              let coefficients = out.featureValue(for: "mask_coefficients")?.multiArrayValue,
              let prototypes = out.featureValue(for: "mask_prototypes")?.multiArrayValue,
              prototypes.shape.map(\.intValue) == [32, 160, 160],
              coefficients.shape.map(\.intValue) == [scores.count, 32],
              prototypes.dataType == .float32, coefficients.dataType == .float32,
              boxes.shape.map(\.intValue) == [scores.count, 4], labels.count == scores.count,
              content.width > 0, content.height > 0 else { return nil }
        var selected: Int?, selectedBox = CGRect.zero, best = Float(0)
        for i in 0..<scores.count where labels[i].intValue == 37 && (selectedIndex == nil || selectedIndex == i) {
            let score = scores[i].floatValue
            guard score.isFinite, score >= Float(threshold), score > best else { continue }
            let b = (0..<4).map { Double(boxes[[NSNumber(value: i), NSNumber(value: $0)]].floatValue) / 640 }
            guard b.allSatisfy(\.isFinite), b[2] > b[0], b[3] > b[1] else { continue }
            let rect = CGRect(x: b[0], y: b[1], width: b[2]-b[0], height: b[3]-b[1]).intersection(content)
            guard !rect.isNull, !rect.isEmpty else { continue }
            selected = i; selectedBox = rect; best = score
        }
        guard let selected else { return nil }
        let cp = coefficients.dataPointer.assumingMemoryBound(to: Float.self)
        let cs = coefficients.strides.map(\.intValue)
        let weights = (0..<32).map { cp[selected * cs[0] + $0 * cs[1]] }
        guard weights.allSatisfy(\.isFinite) else { return nil }
        let pp = prototypes.dataPointer.assumingMemoryBound(to: Float.self)
        let ps = prototypes.strides.map(\.intValue)
        var logits = [Float](repeating: 0, count: 160 * 160)
        if ps == [25600, 160, 1] {
            vDSP_mmul(weights, 1, pp, 1, &logits, 1, 1, 25600, 32)
        } else {
            for c in 0..<32 { for y in 0..<160 { for x in 0..<160 {
                logits[y*160+x] += weights[c] * pp[c*ps[0]+y*ps[1]+x*ps[2]]
            } } }
        }
        // Sample logits in source coordinates, then threshold. Limit retained
        // storage to a 128-square byte patch even for a very close ball.
        // The detector rectangle can clip the learned rim. A half-prototype-cell
        // halo lets the network supply the edge; it never expands an empty mask.
        // A magnified crop maps the normal two-model-pixel halo to less than
        // one source pixel. Appearance recovery can request enough current
        // image context for the round-body fit; logits still determine alpha.
        // The default preserves the existing full-frame decoder exactly.
        let borderX = max(2.0/640, sourceBorder*content.width/sourceSize.width)
        let borderY = max(2.0/640, sourceBorder*content.height/sourceSize.height)
        selectedBox = selectedBox.insetBy(dx: -borderX, dy: -borderY).intersection(content)
        let rect = CGRect(x: (selectedBox.minX-content.minX)/content.width,
                          y: (selectedBox.minY-content.minY)/content.height,
                          width: selectedBox.width/content.width, height: selectedBox.height/content.height)
        let w = min(128, max(8, Int(ceil(rect.width * sourceSize.width))))
        let h = min(128, max(8, Int(ceil(rect.height * sourceSize.height))))
        var binary = [UInt8](repeating: 0, count: w*h)
        // The sampling coordinates are separable. Calculate each axis once,
        // retaining the same floating-point operations and interpolation order.
        let columns = (0..<w).map { x -> (Int, Float) in
            let u = max(0, min(158.999, (selectedBox.minX + (Double(x)+0.5)/Double(w)*selectedBox.width)*160-0.5))
            let ix = Int(u)
            return (ix, Float(u-Double(ix)))
        }
        for y in 0..<h {
            let v = max(0, min(158.999, (selectedBox.minY + (Double(y)+0.5)/Double(h)*selectedBox.height)*160-0.5))
            let iy = Int(v), fy = Float(v-Double(iy))
            for x in 0..<w {
                let (ix, fx) = columns[x]
                let a = logits[iy*160+ix]*(1-fx)+logits[iy*160+ix+1]*fx
                let b = logits[(iy+1)*160+ix]*(1-fx)+logits[(iy+1)*160+ix+1]*fx
                binary[y*w+x] = a*(1-fy)+b*fy > 0 ? 255 : 0
            }
        }
        guard binary.contains(255) else { return nil }
        return BallMask(rect: rect, width: w, height: h,
                        alpha: featheredCoverage(binary, width: w, height: h))
    }

    /// Exact separable 3×3 dilation and [1,2,1] feather. Keep intermediate
    /// integers unrounded; divide only after both axes, including at the edges.
    static func featheredCoverage(_ binary: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        precondition(w > 0 && h > 0 && binary.count == w*h)
        var horizontal = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            horizontal[i] = max(binary[i], max(binary[y*w+max(0,x-1)], binary[y*w+min(w-1,x+1)]))
        } }
        var expanded = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            expanded[i] = max(horizontal[i], max(horizontal[max(0,y-1)*w+x], horizontal[min(h-1,y+1)*w+x]))
        } }
        var sums = [UInt16](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            sums[i] = UInt16(expanded[i])*2
                + (x > 0 ? UInt16(expanded[i-1]) : 0)
                + (x+1 < w ? UInt16(expanded[i+1]) : 0)
        } }
        var alpha = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            let sum = sums[i]*2 + (y > 0 ? sums[i-w] : 0) + (y+1 < h ? sums[i+w] : 0)
            alpha[i] = UInt8(sum/16)
        } }
        return alpha
    }
}
