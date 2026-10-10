import CoreGraphics
import CoreVideo
import Foundation
import simd

/// A bounded, current-frame outline for opaque ball materials. This deliberately
/// does not change the detector, the saved visual track, or surrounding effects.
/// It is a local silhouette approximation, not general occlusion segmentation.
nonisolated struct BallReplacementFootprint {
    let sourceSize: CGSize
    let center: CGPoint
    let radius: Double
    let radii: [Double]
    let feather: Double
    let padding: Double
    /// Estimated source edge blur (sigma in source pixels), for material detail only.
    var textureBlur: Double = 0

    private static let count = 64
    private static let directions = (0..<count).map { i in
        SIMD2(cos(Double(i) * 2 * .pi / Double(count)), sin(Double(i) * 2 * .pi / Double(count)))
    }

    static func fit(pixels: CVPixelBuffer, sample: BallStyleSample, measureTexture: Bool = false) -> Self? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        return fit(bytes: bytes, stride: CVPixelBufferGetBytesPerRow(pixels), size: size,
                   origin: .zero, patchSize: size, sample: sample, measureTexture: measureTexture)
    }

    static func fit(image: CGImage, sample: BallStyleSample, measureTexture: Bool = false) -> Self? {
        let size = CGSize(width: image.width, height: image.height)
        guard let initial = initial(size: size, sample: sample) else { return nil }
        let reach = initial.radius * 2.65 + 6*pixelScale(size)
        let rect = CGRect(x: initial.center.x-reach, y: initial.center.y-reach,
                          width: reach*2, height: reach*2).integral
            .intersection(CGRect(origin: .zero, size: size))
        guard !rect.isNull, !rect.isEmpty, let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: crop.width, height: crop.height,
                  bitsPerComponent: 8, bytesPerRow: crop.width*4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return fit(bytes: bytes, stride: crop.width*4, size: size, origin: rect.origin,
                   patchSize: rect.size, sample: sample, measureTexture: measureTexture)
    }

    // Keep edge softness/coverage comparable when replay decodes the original
    // 4K frame but export uses 720p or 1080p upright SDR pixels.
    private static func pixelScale(_ size: CGSize) -> Double {
        max(0.25, min(size.width, size.height)/720)
    }

    private static func initial(size: CGSize, sample: BallStyleSample) -> (center: CGPoint, radius: Double)? {
        let radius = Double(sample.pixelRadius(in: size))
        let center = CGPoint(x: sample.center.x*size.width, y: sample.center.y*size.height)
        guard sample.visibility > 0.01, center.x.isFinite, center.y.isFinite, radius.isFinite,
              radius >= 4, radius < min(size.width, size.height)*0.24,
              center.x >= 0, center.y >= 0, center.x < size.width, center.y < size.height else { return nil }
        return (center, radius)
    }

    private static func fit(bytes: UnsafePointer<UInt8>, stride: Int, size: CGSize,
                            origin: CGPoint, patchSize: CGSize, sample: BallStyleSample, measureTexture: Bool) -> Self? {
        guard let initial = initial(size: size, sample: sample) else { return nil }
        let r0 = initial.radius, c0 = SIMD2(Double(initial.center.x), Double(initial.center.y))
        func color(_ p: SIMD2<Double>) -> SIMD3<Double> {
            let x = max(0, min(patchSize.width-1, p.x-origin.x))
            let y = max(0, min(patchSize.height-1, p.y-origin.y))
            let ix = Int(x), iy = Int(y), nx = min(Int(patchSize.width)-1, ix+1), ny = min(Int(patchSize.height)-1, iy+1)
            func at(_ xx: Int, _ yy: Int) -> SIMD3<Double> {
                let q = bytes + yy*stride + xx*4
                return SIMD3(Double(q[0]), Double(q[1]), Double(q[2]))
            }
            let a = at(ix, iy)*(1-(x-Double(ix))) + at(nx, iy)*(x-Double(ix))
            let b = at(ix, ny)*(1-(x-Double(ix))) + at(nx, ny)*(x-Double(ix))
            return a*(1-(y-Double(iy))) + b*(y-Double(iy))
        }
        func difference(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let d = simd_abs(a-b); return max(d.x, d.y, d.z)
        }
        let scale = pixelScale(size)
        let shell = max(1.2*scale, r0*0.045)
        func score(_ center: SIMD2<Double>, _ radius: Double) -> Double {
            var support = [Double](); support.reserveCapacity(32)
            for i in Swift.stride(from: 0, to: count, by: 2) {
                let d = directions[i]
                let inside = color(center+d*(radius-shell))
                let outside = color(center+d*(radius+shell))
                let beyond = color(center+d*(radius+shell*3))
                let edge = min(1, difference(inside, outside)/48)
                let continuation = min(1, difference(outside, beyond)/48)
                support.append(max(0, edge-continuation*0.25))
            }
            support.sort()
            // Require distributed support around the circle, rather than one
            // bright printed panel or a straight leg/background boundary.
            let consensus = support.reduce(0,+)/32*0.5 + support[4..<24].reduce(0,+)/20*0.5
            return consensus*100 - simd_length(center-c0)/r0*8 - abs(log(radius/r0))*12
        }
        var center = c0, radius = r0, quality = score(c0, r0)
        var seeds: [(SIMD2<Double>, Double, Double)] = [(c0,r0,quality)]
        // The detector can briefly lock onto a printed panel or shift onto a
        // nearby limb. Search within one observed radius, refining several
        // hypotheses so the coarse grid cannot discard the true outer edge.
        // No accumulated prior: replay seeks and exports agree.
        for ix in -6...6 { for iy in -6...6 { for factor in [0.95,1.05,1.15,1.25,1.35,1.45] {
            let candidate = c0 + SIMD2(Double(ix),Double(iy))*r0*0.15
            guard simd_length(candidate-c0) <= r0 else { continue }
            let value = score(candidate,r0*factor)
            seeds.append((candidate,r0*factor,value))
        } } }
        seeds.sort { $0.2 > $1.2 }
        for seed in seeds.prefix(12) {
            var localCenter=seed.0, localRadius=seed.1, localQuality=seed.2
            for step in [0.07,0.025,0.008] {
                let baseCenter=localCenter, baseRadius=localRadius
                for ix in -1...1 { for iy in -1...1 { for ir in -1...1 {
                let candidate=baseCenter+SIMD2(Double(ix),Double(iy))*r0*step
                let candidateRadius=baseRadius+Double(ir)*r0*step
                guard simd_length(candidate-c0) <= r0, candidateRadius >= r0*0.90,
                      candidateRadius <= r0*1.48 else { continue }
                let value=score(candidate,candidateRadius)
                if value > localQuality { localCenter=candidate; localRadius=candidateRadius; localQuality=value }
                } } }
            }
            if localQuality > quality { center=localCenter; radius=localRadius; quality=localQuality }
        }
        guard quality >= 42 else { return nil }
        var radii = [Double](repeating: radius, count: count)
        var softness = [Double]()
        for i in 0..<count {
            let d = directions[i]
            var best = -Double.infinity
            for j in 0...12 {
                let candidate = radius*(0.90+Double(j)*0.02)
                let inside = color(center+d*(candidate-shell))
                let outside = color(center+d*(candidate+shell))
                let beyond = color(center+d*(candidate+shell*3))
                // Prefer the outer transition into background over a printed
                // panel seam; penalize another large change just beyond it.
                let edge = min(100, difference(inside,outside))
                let value = edge - min(60,difference(outside,beyond))*0.3
                    - pow(candidate/radius-1,2)*220
                if value > best { best = value; radii[i] = candidate }
            }
            let edge = radii[i]
            let narrow = difference(color(center+d*(edge-0.7*scale)), color(center+d*(edge+0.7*scale)))
            let wide = difference(color(center+d*(edge-3*scale)), color(center+d*(edge+3*scale)))
            if wide > 35 { softness.append(max(0.8,min(2.4,2.4-narrow/wide*1.6))*scale) }
        }
        // Printed seams and background texture can win individual rays. Fit
        // only the first two angular harmonics: translation and mild ellipticity.
        // This keeps a smooth ball silhouette instead of tracing those details.
        let raw = radii
        let median = (0..<count).map { i in
            (-2...2).map { raw[(i+$0+count)%count] }.sorted()[2]
        }
        let mean = max(radius*0.98, median.reduce(0,+)/Double(count))
        var coefficients = [Double](repeating: 0, count: 4)
        for i in 0..<count {
            let angle = Double(i)*2 * .pi/Double(count)
            for order in 1...2 {
                coefficients[(order-1)*2] += (median[i]-mean)*cos(angle*Double(order))*2/Double(count)
                coefficients[(order-1)*2+1] += (median[i]-mean)*sin(angle*Double(order))*2/Double(count)
            }
        }
        for order in 0...1 {
            let a = coefficients[order*2], b = coefficients[order*2+1]
            let limit = radius*(order == 0 ? 0.09 : 0.06)
            let scale = min(1,limit/max(hypot(a,b),0.001))
            coefficients[order*2] *= scale; coefficients[order*2+1] *= scale
        }
        for i in 0..<count {
            let angle = Double(i)*2 * .pi/Double(count)
            radii[i] = mean + coefficients[0]*cos(angle) + coefficients[1]*sin(angle)
                + coefficients[2]*cos(angle*2) + coefficients[3]*sin(angle*2)
        }
        softness.sort()
        let feather = softness.isEmpty ? 1.2*scale : softness[softness.count/2]
        var textureBlur=0.0
        if measureTexture {
            var estimates=[Double]()
            for i in Swift.stride(from:0,to:count,by:2) {
                let direction=directions[i],edge=radii[i]
                let positions=Self.blurOffsets.map {center+direction*(edge+$0*scale)}
                guard positions.allSatisfy({$0.x>=1 && $0.y>=1 && $0.x<size.width-1 && $0.y<size.height-1}) else {continue}
                let colors=positions.map(color)
                let inside=colors.prefix(5).reduce(SIMD3<Double>.zero,+)/5
                let outside=colors.suffix(5).reduce(SIMD3<Double>.zero,+)/5
                let delta=inside-outside,norm=simd_length_squared(delta)
                let variation=colors.suffix(5).reduce(SIMD3<Double>.zero) {$0+($1-outside)*($1-outside)}/5
                guard norm>900,max(variation.x,variation.y,variation.z)<100 else {continue}
                let profile=colors.map {simd_dot($0-outside,delta)/norm}
                var bestError=0.025,bestSigma=0.0
                for candidate in Self.blurProfiles {
                    var error=0.0
                    for j in profile.indices {let d=profile[j]-candidate.values[j];error += d*d}
                    error /= Double(profile.count)
                    if error<bestError {bestError=error;bestSigma=candidate.sigma}
                }
                if bestSigma>0 {estimates.append(bestSigma)}
            }
            // Reject cluttered/occluded edges. Never infer exposure from FPS or
            // velocity: a fast ball photographed sharply must remain sharp.
            if estimates.count>=8 {
                estimates.sort();textureBlur=min(3*scale,radius*0.08,estimates[estimates.count/2]*scale)
            }
        }
        return Self(sourceSize: size, center: CGPoint(x:center.x,y:center.y), radius: radius,
                    radii: radii, feather: feather, padding: max(1.4*scale,min(3*scale,radius*0.045)),
                    textureBlur:textureBlur)
    }

    private static let blurOffsets=(0...40).map {Double($0)*0.5-10}
    private struct BlurProfile {let sigma:Double;let values:[Double]}
    private static let blurProfiles: [BlurProfile] = {
        var result=[BlurProfile]()
        for sigma in [0.4,0.7,1.0,1.5,2.0,3.0,4.0] {
            for shift in [-3.0,-1.5,0.0,1.5,3.0] {
                let values=blurOffsets.map {0.5*(1-erf(($0-shift)/(sigma*sqrt(2))))}
                result.append(BlurProfile(sigma:sigma,values:values))
            }
        }
        return result
    }()

    func edge(at angle: Double) -> Double {
        let phase = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi) * Double(radii.count)
        let i = Int(phase), fraction = phase-Double(i)
        return radii[i % radii.count]*(1-fraction) + radii[(i+1) % radii.count]*fraction
    }
}
