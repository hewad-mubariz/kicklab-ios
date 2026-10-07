import CoreGraphics
import CoreVideo
import Foundation

/// Local silhouette refinement, constrained to the existing visual detector.
/// It samples outward color edges instead of keeping a rectangle of old grass.
/// This is a ball-specific approximation, not a general instance segmenter.
nonisolated enum BallForegroundMask {
    struct Patch { let pixels: CVPixelBuffer; let rect: CGRect }

    static func make(source: CVPixelBuffer, bounds: CGRect, refineBounds:Bool = true) throws -> Patch? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        var cx = Double(bounds.midX) * Double(w), cy = Double(bounds.midY) * Double(h)
        var radius = min(Double(bounds.width) * Double(w), Double(bounds.height) * Double(h)) / 2
        guard cx.isFinite, cy.isFinite, radius.isFinite, radius >= 3,
              radius < Double(min(w, h)) * 0.3,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let data = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(source), count = 64
        func color(_ x: Double, _ y: Double) -> SIMD3<Double> {
            let xx = min(w-1, max(0, Int(x.rounded()))), yy = min(h-1, max(0, Int(y.rounded())))
            let p = data + yy*stride + xx*4
            return SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
        }
        let initialX = cx, initialY = cy, initialRadius = radius
        func perimeterScore(_ x: Double, _ y: Double, _ r: Double) -> Double {
            var edges: [Double] = [], signed: Double = 0
            for i in 0..<32 {
                let a = Double(i)/32 * .pi*2, dx = cos(a), dy = sin(a), shell = max(1.2,r*0.08)
                let inner = color(x+dx*(r-shell),y+dy*(r-shell))
                let outer = color(x+dx*(r+shell),y+dy*(r+shell))
                let delta = (inner.x-outer.x)*0.20+(inner.y-outer.y)*0.50+(inner.z-outer.z)*0.30
                signed += max(-90,min(90,delta)); edges.append(abs(delta))
            }
            edges.sort()
            let rim = edges[6..<25].reduce(0,+)/19
            return rim*0.4 + abs(signed/32) - hypot(x-initialX,y-initialY)/initialRadius*4
                - abs(log(r/initialRadius))*12
        }
        var best = perimeterScore(cx,cy,radius)
        for scale in refineBounds ? [0.85,0.93,1.0,1.07] : [] {
            for ix in -3...3 { for iy in -3...3 {
                let x=initialX+Double(ix)*initialRadius*0.12, y=initialY+Double(iy)*initialRadius*0.12
                let r=initialRadius*scale, score=perimeterScore(x,y,r)
                if score>best {best=score;cx=x;cy=y;radius=r}
            } }
        }
        let patch = CGRect(x: cx-radius*1.35-2, y: cy-radius*1.35-2, width: radius*2.7+4, height: radius*2.7+4)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !patch.isEmpty, !patch.isNull else { return nil }
        var radii = [Double](repeating: radius, count: count)
        let shell = max(1, radius * 0.04)
        for i in 0..<count {
            let angle = Double(i) / Double(count) * .pi * 2, dx = cos(angle), dy = sin(angle)
            var best = -Double.infinity
            for j in 0...16 {
                let candidate = radius * (refineBounds ? (0.82 + Double(j)*0.025):(0.91 + Double(j)*0.01))
                let inside = color(cx+dx*(candidate-shell), cy+dy*(candidate-shell))
                let outside = color(cx+dx*(candidate+shell), cy+dy*(candidate+shell))
                let delta = abs(inside.x-outside.x)*0.25 + abs(inside.y-outside.y)*0.45 + abs(inside.z-outside.z)*0.30
                // A panel seam deep in the ball or an adjacent shoe is not its edge.
                let score = min(90, delta) - pow((candidate-radius)/radius, 2)*420
                if score > best { best = score; radii[i] = candidate }
            }
        }
        // Spatial contour regularity; no temporal averaging that trails a fast ball.
        let raw = radii
        for i in 0..<count {
            let neighborhood = (-2...2).map { raw[(i+$0+count)%count] }.sorted()
            radii[i] = neighborhood[2]*0.6 + radius*0.4
        }
        let output = try ForegroundMaskProcessor.buffer(width: Int(patch.width), height: Int(patch.height), format: kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(output)
        let feather = max(0.85, min(2.0, radius*0.035))
        for y in 0..<Int(patch.height) { for x in 0..<Int(patch.width) {
            let dx = Double(x)+patch.minX+0.5-cx, dy = Double(y)+patch.minY+0.5-cy
            let angle = (atan2(dy, dx) + .pi*2).truncatingRemainder(dividingBy: .pi*2) / (.pi*2) * Double(count)
            let index = Int(angle), fraction = angle - Double(index)
            let edge = radii[index%count]*(1-fraction) + radii[(index+1)%count]*fraction - min(0.9,radius*0.035)
            let value = min(1, max(0, (edge-hypot(dx,dy))/feather + 0.5))
            bytes[y*row+x] = UInt8((value*value*(3-2*value)*255).rounded())
        } }
        return Patch(pixels: output, rect: CGRect(x: patch.minX/Double(w), y: patch.minY/Double(h),
            width: patch.width/Double(w), height: patch.height/Double(h)))
    }
}
