import CoreGraphics
import Foundation
import simd

/// Textured football materials. Surrounding effects remain a separate Metal pass.
nonisolated enum BallMaterialRenderer {
    struct Replacement {
        let image: CGImage
        /// Top-left normalized source coordinates, independent of output size.
        let rect: CGRect
        let footprint: BallReplacementFootprint
    }

    static func draw(in ctx: CGContext, size: CGSize, sourceSize: CGSize,
                     skin: BallSkin, sample: BallStyleSample?, time: Double,
                     replacement: Replacement? = nil) {
        guard skin != .original, let sample, sample.visibility > 0.01 else { return }
        let rect = EffectVideoGeometry.aspectFillRect(source: sourceSize, destination: size)
        let center = CGPoint(x: rect.minX + sample.center.x * rect.width, y: rect.minY + sample.center.y * rect.height)
        let radius = max(2, sample.pixelRadius(in: rect.size))
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        ctx.setAlpha(sample.visibility)
        if let replacement {
            let target = CGRect(x: rect.minX + replacement.rect.minX*rect.width,
                                y: rect.minY + replacement.rect.minY*rect.height,
                                width: replacement.rect.width*rect.width, height: replacement.rect.height*rect.height)
            // The public drawing context is top-left; CGImage drawing is y-up.
            ctx.translateBy(x: target.minX, y: target.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(replacement.image, in: CGRect(origin: .zero, size: target.size))
        } else {
            drawSkin(ctx, center: center, radius: radius * 1.04, skin: skin, time: time)
        }
        ctx.restoreGState()
    }

    /// Rasterize only a small ball patch. Both replay and export use the same
    /// per-frame footprint and premultiplied pixels; no full-frame segmentation.
    static func replacement(footprint f: BallReplacementFootprint?, skin: BallSkin, time: Double,
                            coverage: ((Double, Double) -> Double)? = nil) -> Replacement? {
        guard skin != .original, let f, BallSkinSphereRenderer.hasArtwork(for: skin) else { return nil }
        let extent = (f.radii.max() ?? f.radius) + f.padding + f.feather + 2
        let dimension = min(256, max(16, Int(ceil(extent*2))))
        let step = extent*2/Double(dimension)
        let textureSize = 192, textureCenter = 96.0, textureRadius = 92.0
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let material = CGContext(data: nil, width: textureSize, height: textureSize,
            bitsPerComponent: 8, bytesPerRow: textureSize*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let bytes = material.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        material.translateBy(x: 0,y: CGFloat(textureSize)); material.scaleBy(x: 1,y: -1)
        drawSkin(material, center: CGPoint(x:textureCenter,y:textureCenter), radius:textureRadius,skin:skin,time:time)
        let raw = Array(UnsafeBufferPointer(start: bytes, count:textureSize*textureSize*4))
        var texture = raw
        // A photographed ball's surface should not be sharper than its rim.
        let blur = min(2, max(1, Int((f.feather*textureRadius/max(f.radius,1)*0.65).rounded())))
        // Separable box blur keeps work linear in patch area.
        let span = blur*2+1
        var horizontal = [Int](repeating: 0, count: raw.count)
        for y in 0..<textureSize { for channel in 0..<3 {
            var sum = (0...blur*2).reduce(0) { $0 + Int(raw[(y*textureSize+$1)*4+channel]) }
            for x in blur..<(textureSize-blur) {
                horizontal[(y*textureSize+x)*4+channel] = sum
                if x+blur+1 < textureSize {
                    sum += Int(raw[(y*textureSize+x+blur+1)*4+channel])
                        - Int(raw[(y*textureSize+x-blur)*4+channel])
                }
            }
        } }
        for x in blur..<(textureSize-blur) { for channel in 0..<3 {
            var sum = (0...blur*2).reduce(0) { $0 + horizontal[($1*textureSize+x)*4+channel] }
            for y in blur..<(textureSize-blur) {
                texture[(y*textureSize+x)*4+channel] = UInt8(sum/(span*span))
                if y+blur+1 < textureSize {
                    sum += horizontal[((y+blur+1)*textureSize+x)*4+channel]
                        - horizontal[((y-blur)*textureSize+x)*4+channel]
                }
            }
        } }
        var output = [UInt8](repeating: 0, count: dimension*dimension*4)
        for y in 0..<dimension { for x in 0..<dimension {
            let dx = (Double(x)+0.5)*step-extent, dy = (Double(y)+0.5)*step-extent
            let distance = hypot(dx,dy), edge = f.edge(at:atan2(dy,dx)) + f.padding
            let value = max(0,min(1,(edge-distance)/f.feather+0.5))
            let alpha = coverage.map { $0(f.center.x+dx, f.center.y+dy) } ?? (value*value*(3-2*value))
            guard alpha > 0 else { continue }
            // Map the sphere to its fitted silhouette so shading reaches the
            // real edge, instead of laying a small circular sticker inside it.
            let scale = textureRadius/max(edge,1)
            let radialLimit = min(1,edge/max(distance,0.001))*0.975
            let tx = textureCenter + dx*scale*radialLimit
            let ty = textureCenter + dy*scale*radialLimit
            let ix = Int(tx), iy = Int(ty), fx = tx-Double(ix), fy = ty-Double(iy)
            let offset = (y*dimension+x)*4
            for channel in 0..<3 {
                func v(_ xx:Int,_ yy:Int)->Double { Double(texture[(yy*textureSize+xx)*4+channel]) }
                let a = v(ix,iy)*(1-fx)+v(ix+1,iy)*fx
                let b = v(ix,iy+1)*(1-fx)+v(ix+1,iy+1)*fx
                output[offset+channel] = UInt8(max(0,min(255,((a*(1-fy)+b*fy)*alpha).rounded())))
            }
            output[offset+3] = UInt8((alpha*255).rounded())
        } }
        guard let provider = CGDataProvider(data:Data(output) as CFData),
              let image = CGImage(width:dimension,height:dimension,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:dimension*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:info),
                provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
        return Replacement(image:image,rect:CGRect(x:(f.center.x-extent)/f.sourceSize.width,
            y:(f.center.y-extent)/f.sourceSize.height,width:extent*2/f.sourceSize.width,height:extent*2/f.sourceSize.height),footprint:f)
    }

    /// Draw the same material used by replay/export in the style picker.
    static func drawSkin(_ ctx: CGContext, center: CGPoint, radius: Double, skin: BallSkin, time: Double) {
        guard radius > 0, let image = BallSkinSphereRenderer.image(skin: skin, time: time) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x-radius, y: center.y+radius)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x:0,y:0,width:radius*2,height:radius*2))
        ctx.restoreGState()
    }
}
