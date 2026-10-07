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
                       threshold: Double, selectedIndex: Int? = nil) -> BallMask? {
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
        selectedBox = selectedBox.insetBy(dx: -2.0/640, dy: -2.0/640).intersection(content)
        let rect = CGRect(x: (selectedBox.minX-content.minX)/content.width,
                          y: (selectedBox.minY-content.minY)/content.height,
                          width: selectedBox.width/content.width, height: selectedBox.height/content.height)
        let w = min(128, max(8, Int(ceil(rect.width * sourceSize.width))))
        let h = min(128, max(8, Int(ceil(rect.height * sourceSize.height))))
        var binary = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let u = max(0, min(158.999, (selectedBox.minX + (Double(x)+0.5)/Double(w)*selectedBox.width)*160-0.5))
            let v = max(0, min(158.999, (selectedBox.minY + (Double(y)+0.5)/Double(h)*selectedBox.height)*160-0.5))
            let ix = Int(u), iy = Int(v), fx = Float(u-Double(ix)), fy = Float(v-Double(iy))
            let a = logits[iy*160+ix]*(1-fx)+logits[iy*160+ix+1]*fx
            let b = logits[(iy+1)*160+ix]*(1-fx)+logits[(iy+1)*160+ix+1]*fx
            binary[y*w+x] = a*(1-fy)+b*fy > 0 ? 255 : 0
        } }
        guard binary.contains(255) else { return nil }
        // One-pixel coverage expansion followed by a small feather. No temporal
        // holding: every patch belongs to its own observed video frame.
        var expanded = binary
        for y in 0..<h { for x in 0..<w {
            var value: UInt8 = 0
            for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
                value = max(value, binary[yy*w+xx])
            } }
            expanded[y*w+x] = value
        } }
        var alpha = expanded
        for y in 0..<h { for x in 0..<w {
            var sum = 0
            for dy in -1...1 { for dx in -1...1 {
                let yy = y+dy, xx = x+dx
                if yy >= 0, yy < h, xx >= 0, xx < w {
                    sum += Int(expanded[yy*w+xx]) * (dy == 0 ? 2 : 1) * (dx == 0 ? 2 : 1)
                }
            } }
            alpha[y*w+x] = UInt8(sum/16)
        } }
        return BallMask(rect: rect, width: w, height: h, alpha: alpha)
    }
}
