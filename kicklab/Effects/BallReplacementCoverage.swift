import CoreGraphics
import Foundation

/// One replacement silhouette per frame, from one rule. Size and centre come from
/// the image-edge fit, held within the larger of ±6% or mask sampling uncertainty
/// around a robust circle through the owned mask
/// (corrected for the mask's measured outward bias). The mask only removes
/// coverage where a deficit reaches deep inside the ball, such as fingers; shallow
/// rim deficits are mask quantization or patch cropping, not occluders.
/// Detection observations and their masks remain immutable.
nonisolated struct BallReplacementCoverage {
    let footprint: BallReplacementFootprint
    let bounds: CGRect
    let reconstructsBody: Bool
    private let mask: BallMask
    private let body: BallReplacementFootprint?
    private let cut: CutGrid?
    private let smear: CGVector
    private let smearSteps: Int
    /// Per-direction weight (64 rays from the body centre) where the owned mask
    /// extends beyond mask sampling bias, with support on the opposite side.
    /// An isolated mask protrusion is not evidence of exposure blur.
    private let lobes: [Double]

    /// The owned mask's 0.5 contour sits about 1.5 mask pixels outside the
    /// photographed ball (3×3 dilation plus feather), measured on reviewed frames.
    static let maskOutwardBias = 1.5
    /// The image-edge fit is trusted within this band around the mask circle.
    static let fitBand = 0.06

    init(mask: BallMask, fitted: BallReplacementFootprint?, size: CGSize, smear: CGVector = .zero) {
        self.mask = mask
        let scale = max(0.25, min(size.width, size.height)/720)
        let length = hypot(smear.dx, smear.dy)
        self.smear = length > 0.75*scale ? smear : .zero
        smearSteps = length > 0.75*scale ? min(12, max(2, Int(ceil(length/(1.5*scale))))) : 1
        let maskBounds = CGRect(x: mask.rect.minX*size.width, y: mask.rect.minY*size.height,
                                width: mask.rect.width*size.width, height: mask.rect.height*size.height)
        guard let circle = Self.maskCircle(mask: mask, bounds: maskBounds, size: size) else {
            body = nil; cut = nil; reconstructsBody = false; bounds = maskBounds; lobes = []
            footprint = fitted.map { Self.materialFootprint(mask: mask, fitted: $0, base: mask.footprint(in: size), bounds: maskBounds) }
                ?? mask.footprint(in: size)
            return
        }
        var b = BallReplacementFootprint(sourceSize: size, center: circle.center, radius: circle.radius,
            radii: Array(repeating: circle.radius, count: 64), feather: 1.2*scale, padding: 0, textureBlur: fitted?.textureBlur ?? 0)
        let maskPixel = max(maskBounds.width/Double(mask.width), maskBounds.height/Double(mask.height))
        // At distant sizes a mask pixel can exceed the percentage-only tolerance.
        // Account for the decoder's two-sided outward bias when trusting a current
        // image-edge fit; keep the established relative limits for larger balls.
        let centerTolerance = max(circle.radius*0.25, 2*Self.maskOutwardBias*maskPixel)
        if let f = fitted, hypot(f.center.x-circle.center.x, f.center.y-circle.center.y) < centerTolerance {
            let mean = f.radii.reduce(0, +)/Double(f.radii.count)
            let radiusTolerance = max(circle.radius*Self.fitBand, Self.maskOutwardBias*maskPixel)
            let low = max(2*scale, circle.radius-radiusTolerance), high = circle.radius+radiusTolerance
            if mean >= low && mean <= high {
                b = BallReplacementFootprint(sourceSize: f.sourceSize, center: f.center, radius: mean, radii: f.radii,
                                             feather: f.feather, padding: 0, textureBlur: f.textureBlur)
            } else {
                // A fit outside the band has locked onto a sharp core or a hand.
                // Keep the mask circle's centre and the nearest trusted size.
                let r = min(max(mean, low), high)
                b = BallReplacementFootprint(sourceSize: size, center: circle.center, radius: r,
                    radii: Array(repeating: r, count: 64), feather: f.feather, padding: 0, textureBlur: f.textureBlur)
            }
        }
        // Cover the photographed ball's anti-aliased rim: grow the body uniformly.
        b = BallReplacementFootprint(sourceSize: b.sourceSize, center: b.center, radius: b.radius+0.5*scale,
            radii: b.radii.map { $0+0.5*scale }, feather: b.feather, padding: 0, textureBlur: b.textureBlur)
        body = b; footprint = b; reconstructsBody = true
        cut = CutGrid(mask: mask, body: b, maskBounds: maskBounds, size: size)
        lobes = Self.lobes(mask: mask, body: b, maskBounds: maskBounds, size: size)
        let extent = (b.radii.max() ?? b.radius) + b.feather + hypot(self.smear.dx, self.smear.dy)/2
        bounds = CGRect(x: b.center.x-extent, y: b.center.y-extent, width: extent*2, height: extent*2).union(maskBounds)
    }

    func coverage(x: Double, y: Double) -> Double {
        guard let body else {
            return mask.coverage(x: x/footprint.sourceSize.width, y: y/footprint.sourceSize.height)
        }
        // The camera integrates the ball over the exposure: average the body along
        // the smear. Occluders (hands, feet) stay at their own photographed edges.
        var v = 0.0
        for i in 0..<smearSteps {
            let t = smearSteps == 1 ? 0 : (Double(i)+0.5)/Double(smearSteps)-0.5
            v += Self.bodyCoverage(body, x: x-smear.dx*t, y: y-smear.dy*t)
        }
        v /= Double(smearSteps)
        if v > 0, let cut { v *= cut.visibility(x: x, y: y) }
        // The owned mask is trained on photographed balls, so it reaches into motion
        // smear the body model misses. Pulled in by its measured outward bias, it may
        // extend coverage; it never removes body coverage or re-adds an occluder.
        // Blur only lengthens the ball along its motion, so the mask may add
        // coverage only near that axis, and only when the frame is smeared.
        guard smearSteps > 1 || !lobes.isEmpty else { return v }
        let dx = x-body.center.x, dy = y-body.center.y, d = hypot(dx, dy)
        guard d > 1e-6 else { return v }
        var along = 0.0
        if smearSteps > 1 {
            let axis = abs((dx*smear.dx+dy*smear.dy)/(d*hypot(smear.dx, smear.dy)))
            along = min(1, max(0, (axis-0.5)/0.35))
        }
        if !lobes.isEmpty {
            let phase = (atan2(dy, dx)+2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)/(2 * .pi)*64
            let i = Int(phase)%64, f = phase-Double(Int(phase))
            along = max(along, lobes[i]*(1-f)+lobes[(i+1)%64]*f)
        }
        guard along > 0 else { return v }
        let a = mask.coverage(x: x/footprint.sourceSize.width, y: y/footprint.sourceSize.height)
        let inner = min(1, max(0, (a-0.75)/0.22))
        return max(v, inner*inner*(3-2*inner)*along*along*(3-2*along))
    }

    private static func bodyCoverage(_ body: BallReplacementFootprint, x: Double, y: Double) -> Double {
        let dx = x-body.center.x, dy = y-body.center.y
        let value = min(1, max(0, (body.edge(at: atan2(dy, dx))-hypot(dx, dy))/body.feather+0.5))
        return value*value*(3-2*value)
    }

    /// Percentage-only thresholds mistake ordinary mask dilation for blur on a
    /// small ball. Require extension beyond the larger of that percentage and
    /// one measured dilation width. Without track motion, a photographed smear
    /// must also have support across the body; a lone background protrusion cannot
    /// extend the silhouette. The measured-motion path remains independent.
    private static func lobes(mask: BallMask, body: BallReplacementFootprint, maskBounds: CGRect, size: CGSize) -> [Double] {
        let pixel = max(maskBounds.width/Double(mask.width), maskBounds.height/Double(mask.height))
        let threshold = max(0.10*body.radius, maskOutwardBias*pixel)
        let transition = max(0.08*body.radius, pixel)
        var raw = [Double](repeating: 0, count: 64)
        for i in 0..<64 {
            let t = Double(i)*2 * .pi/64, c = cos(t), s = sin(t), edge = body.edge(at: t)
            var outer = edge
            for j in 0..<48 {
                let r = edge*(0.9+Double(j)*0.7/47), px = body.center.x+c*r, py = body.center.y+s*r
                guard maskBounds.contains(CGPoint(x: px, y: py)) else { continue }
                if mask.coverage(x: px/size.width, y: py/size.height) > 0.5 { outer = r }
            }
            raw[i] = min(1, max(0, (outer-edge-threshold)/transition))
        }
        let eroded = (0..<64).map { min(raw[($0+63)%64], raw[$0], raw[($0+1)%64]) }
        let opened = (0..<64).map { max(eroded[($0+63)%64], eroded[$0], eroded[($0+1)%64]) }
        // Permit a small angular deviation for quantized masks and mild curvature.
        // Opposing support rejects one-sided limbs/background, while preserving a
        // photographed elongated ball even if the motion track has no estimate.
        let paired = (0..<64).map { i in
            var opposite = 0.0
            for offset in -2...2 { opposite = max(opposite, opened[(i+96+offset)%64]) }
            return min(opened[i], opposite)
        }
        return paired.contains { $0 > 0 } ? paired : []
    }

    /// Robust circle through the mask's outermost 0.5 crossings. Points on the
    /// patch border (detector-box cropping) are excluded; inward residuals, which
    /// are usually occluders, are down-weighted.
    private static func maskCircle(mask: BallMask, bounds: CGRect, size: CGSize) -> (center: CGPoint, radius: Double)? {
        let scale = max(0.25, min(size.width, size.height)/720)
        let pixelX = bounds.width/Double(mask.width), pixelY = bounds.height/Double(mask.height)
        var sum = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<mask.height { for x in 0..<mask.width {
            let a = Double(mask.alpha[y*mask.width+x])/255
            sum += a; sx += a*(Double(x)+0.5); sy += a*(Double(y)+0.5)
        } }
        guard sum > 4 else { return nil }
        let cx = bounds.minX+sx/sum*pixelX, cy = bounds.minY+sy/sum*pixelY
        let base = max(bounds.width, bounds.height)/2, margin = 2.5*max(pixelX, pixelY)
        func alpha(_ x: Double, _ y: Double) -> Double {
            guard x > bounds.minX, x < bounds.maxX, y > bounds.minY, y < bounds.maxY else { return 0 }
            return mask.coverage(x: x/size.width, y: y/size.height)
        }
        var points = [(Double, Double)](); points.reserveCapacity(96)
        for i in 0..<96 {
            let t = Double(i)*2 * .pi/96, c = cos(t), s = sin(t)
            var last = -1, values = [Double](repeating: 0, count: 160)
            for j in 0..<160 {
                let r = base*(0.05+Double(j)*1.55/159)
                values[j] = alpha(cx+c*r, cy+s*r)
                if values[j] > 0.5 { last = j }
            }
            guard last >= 0, last < 159 else { continue }
            let f = (values[last]-0.5)/max(values[last]-values[last+1], 1e-9)
            let r = base*(0.05+(Double(last)+f)*1.55/159), px = cx+c*r, py = cy+s*r
            guard min(px-bounds.minX, py-bounds.minY, bounds.maxX-px, bounds.maxY-py) >= margin else { continue }
            points.append((px, py))
        }
        guard points.count >= 24 else { return nil }
        var w = [Double](repeating: 1, count: points.count), center = (cx, cy), radius = base
        for _ in 0..<8 {
            var m = Array(repeating: Array(repeating: 0.0, count: 4), count: 3)
            for (i, p) in points.enumerated() {
                let a = [2*(p.0-cx)/base, 2*(p.1-cy)/base, 1.0]
                let b = (pow(p.0-cx, 2)+pow(p.1-cy, 2))/(base*base)
                for j in 0..<3 { for k in 0..<3 { m[j][k] += a[j]*a[k]*w[i] }; m[j][3] += a[j]*b*w[i] }
            }
            guard let q = solve(m) else { return nil }
            center = (cx+q[0]*base, cy+q[1]*base)
            radius = sqrt(max(0, q[2]+q[0]*q[0]+q[1]*q[1]))*base
            let e = points.map { hypot($0.0-center.0, $0.1-center.1)-radius }
            let mad = max(1.4826*(e.map(abs).sorted()[e.count/2]), 0.5*scale)
            for i in e.indices {
                let u = max(-1, min(1, e[i]/(3*mad)))
                w[i] = (1-u*u)*(1-u*u)*(e[i] < -2*mad ? 0.2 : 1)
            }
        }
        let corrected = radius-maskOutwardBias*max(pixelX, pixelY)
        guard corrected > 2*scale, radius < base*1.6 else { return nil }
        return (CGPoint(x: center.0, y: center.1), corrected)
    }

    /// Occluder cut-outs inside the body: mask deficits connected to a seed that
    /// lies deep inside the ball. Inside a cut the owned mask alpha applies.
    private struct CutGrid {
        let origin: CGPoint, step: Double, columns: Int, rows: Int
        let weight: [Float]
        let mask: BallMask, size: CGSize

        init?(mask: BallMask, body: BallReplacementFootprint, maskBounds: CGRect, size: CGSize) {
            let scale = max(0.25, min(size.width, size.height)/720)
            let extent = (body.radii.max() ?? body.radius)
            let step = max(0.75*scale, body.radius/40)
            let n = Int(ceil(extent*2/step))+1
            let origin = CGPoint(x: body.center.x-extent, y: body.center.y-extent)
            let inset = maskBounds.insetBy(dx: maskBounds.width/Double(mask.width), dy: maskBounds.height/Double(mask.height))
            var deficit = [Bool](repeating: false, count: n*n), seeds = [Int]()
            // A mask deficit must have the same physical depth in replay and
            // export. Fixed output pixels made small rim noise become a cut-out
            // when the same owned mask was rendered at a higher resolution.
            let deep = max(0.18*body.radius, 3*scale)
            for j in 0..<n { for i in 0..<n {
                let x = origin.x+Double(i)*step, y = origin.y+Double(j)*step
                let dx = x-body.center.x, dy = y-body.center.y
                let depth = body.edge(at: atan2(dy, dx))-hypot(dx, dy)
                guard depth > 0.5*scale, inset.contains(CGPoint(x: x, y: y)),
                      mask.coverage(x: x/size.width, y: y/size.height) < 0.5 else { continue }
                deficit[j*n+i] = true
                if depth > deep { seeds.append(j*n+i) }
            }}
            guard !seeds.isEmpty else { return nil }
            var cut = [Bool](repeating: false, count: n*n), queue = seeds, head = 0
            for s in seeds { cut[s] = true }
            while head < queue.count {
                let c = queue[head]; head += 1
                let i = c%n, j = c/n
                for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let ii = i+di, jj = j+dj
                    guard ii >= 0, jj >= 0, ii < n, jj < n else { continue }
                    let k = jj*n+ii
                    if deficit[k] && !cut[k] { cut[k] = true; queue.append(k) }
                }
            }
            // Grow by two cells so visibility blends into the owned alpha smoothly.
            var grown = cut
            for _ in 0..<2 {
                var next = grown
                for k in grown.indices where grown[k] {
                    let i = k%n, j = k/n
                    for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let ii = i+di, jj = j+dj
                        if ii >= 0, jj >= 0, ii < n, jj < n { next[jj*n+ii] = true }
                    }
                }
                grown = next
            }
            self.origin = origin; self.step = step; columns = n; rows = n
            weight = grown.map { $0 ? 1 : 0 }; self.mask = mask; self.size = size
        }

        func visibility(x: Double, y: Double) -> Double {
            let u = (x-origin.x)/step, v = (y-origin.y)/step
            guard u >= 0, v >= 0, u < Double(columns-1), v < Double(rows-1) else { return 1 }
            let i = Int(u), j = Int(v), fu = Float(u-Double(i)), fv = Float(v-Double(j))
            let w = (weight[j*columns+i]*(1-fu)+weight[j*columns+i+1]*fu)*(1-fv)
                + (weight[(j+1)*columns+i]*(1-fu)+weight[(j+1)*columns+i+1]*fu)*fv
            guard w > 0 else { return 1 }
            let m = mask.coverage(x: x/size.width, y: y/size.height)
            return 1-Double(w)*(1-m)
        }
    }

    private static func solve(_ input: [[Double]]) -> [Double]? {
        var a = input
        for column in 0..<3 {
            let pivot = (column..<3).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            guard abs(a[pivot][column]) > 1e-9 else { return nil }
            a.swapAt(column, pivot)
            let divisor = a[column][column]
            for j in column..<4 { a[column][j] /= divisor }
            for row in 0..<3 where row != column {
                let multiple = a[row][column]
                for j in column..<4 { a[row][j] -= multiple*a[column][j] }
            }
        }
        return (0..<3).map { a[$0][3] }
    }

    private static func materialFootprint(mask: BallMask, fitted f: BallReplacementFootprint,
                                          base: BallReplacementFootprint, bounds: CGRect) -> BallReplacementFootprint {
        var support = 0.0, outside = 0.0
        let columns = min(32, mask.width), rows = min(32, mask.height)
        for y in 0..<rows { for x in 0..<columns {
            let px = bounds.minX+(Double(x)+0.5)/Double(columns)*bounds.width
            let py = bounds.minY+(Double(y)+0.5)/Double(rows)*bounds.height
            let alpha = mask.coverage(x: px/f.sourceSize.width, y: py/f.sourceSize.height)
            guard alpha > 0.8 else { continue }
            let dx = px-f.center.x, dy = py-f.center.y
            support += alpha
            if hypot(dx, dy) > f.edge(at: atan2(dy, dx))+f.padding+f.feather/2 { outside += alpha }
        } }
        let amount = min(1, max(0, (outside/max(support, 1)-0.03)/0.09))
        guard amount > 0 else { return f }
        let weight = amount*amount*(3-2*amount)
        let rx = max(bounds.width/2, 1), ry = max(bounds.height/2, 1)
        let radii = (0..<64).map { i -> Double in
            let angle = Double(i)*2 * .pi/64
            let ellipse = 1/sqrt(pow(cos(angle)/rx, 2)+pow(sin(angle)/ry, 2))
            return f.edge(at: angle)*(1-weight)+ellipse*weight
        }
        return BallReplacementFootprint(sourceSize: f.sourceSize,
            center: CGPoint(x: f.center.x*(1-weight)+bounds.midX*weight, y: f.center.y*(1-weight)+bounds.midY*weight),
            radius: f.radius*(1-weight)+base.radius*weight, radii: radii, feather: f.feather,
            padding: f.padding*(1-weight), textureBlur: f.textureBlur)
    }
}
