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

    /// One affine projection for the whole sphere. The matte clips visibility;
    /// its individual radial edges must not bend the surface texture independently.
    struct SurfaceProjection {
        let center: CGPoint
        let inverseXX: Double
        let inverseXY: Double
        let inverseYY: Double

        init(footprint f: BallReplacementFootprint) {
            let count = Double(f.radii.count)
            let mean = max(1, f.radii.reduce(0,+)/count+f.padding)
            var x = 0.0, y = 0.0, a = 0.0, b = 0.0
            for (i,radius) in f.radii.enumerated() {
                let angle = Double(i)*2 * .pi/count
                x += radius*cos(angle)*2/count; y += radius*sin(angle)*2/count
                a += radius*cos(2*angle)*2/count; b += radius*sin(2*angle)*2/count
            }
            // First harmonic represents centre offset; second represents the
            // ellipse. Ignore finer contour noise when projecting the material.
            let offsetScale = min(1, mean*0.12/max(hypot(x,y),0.0001))
            center = CGPoint(x:f.center.x+x*offsetScale,y:f.center.y+y*offsetScale)
            let amplitude = min(mean*0.25,hypot(a,b))
            let angle = atan2(b,a)/2, c = cos(angle), s = sin(angle)
            let rx = mean+amplitude, ry = mean-amplitude
            inverseXX = c*c/rx+s*s/ry
            inverseXY = c*s*(1/rx-1/ry)
            inverseYY = s*s/rx+c*c/ry
        }

        /// View-aligned coordinates on the unit sphere, before limb clamping.
        /// Rotating an ellipse's axes does not rotate the printed artwork.
        func point(x: Double, y: Double) -> CGPoint {
            let dx = x-center.x, dy = y-center.y
            return CGPoint(x:inverseXX*dx+inverseXY*dy,y:inverseXY*dx+inverseYY*dy)
        }
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
                            coverage: ((Double, Double) -> Double)? = nil,
                            coverageBounds: CGRect? = nil,
                            orientation: simd_quatf? = nil, smear: CGVector = .zero,
                            light: SIMD3<Float>? = nil) -> Replacement? {
        guard skin != .original, let f, BallSkinSphereRenderer.hasArtwork(for: skin) else { return nil }
        let smearLength = hypot(smear.dx, smear.dy)
        let smearSteps = smearLength > 0.75 ? min(12, max(2, Int(ceil(smearLength/1.5)))) : 1
        var extent = (f.radii.max() ?? f.radius) + f.padding + f.feather + 2 + smearLength/2
        if coverage != nil, let bounds = coverageBounds, !bounds.isNull, !bounds.isEmpty {
            extent = max(extent, max(abs(bounds.minX-f.center.x), abs(bounds.maxX-f.center.x),
                                     abs(bounds.minY-f.center.y), abs(bounds.maxY-f.center.y)) + 2)
        }
        let dimension = min(256, max(16, Int(ceil(extent*2))))
        let step = extent*2/Double(dimension)
        let textureSize = 192, textureCenter = 96.0, textureRadius = 92.0
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let material = CGContext(data: nil, width: textureSize, height: textureSize,
            bitsPerComponent: 8, bytesPerRow: textureSize*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let bytes = material.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        material.translateBy(x: 0,y: CGFloat(textureSize)); material.scaleBy(x: 1,y: -1)
        drawSkin(material, center: CGPoint(x:textureCenter,y:textureCenter), radius:textureRadius,skin:skin,time:time,orientation:orientation)
        let raw = Array(UnsafeBufferPointer(start: bytes, count:textureSize*textureSize*4))
        var texture = raw
        // The print is only prefiltered for minification from the 192 px sphere
        // raster: the real print is about as sharp as the video (measured 1.1-1.3 px
        // sigma on reviewed frames), so rim softness and a fixed floor over-blurred it.
        // Motion blur comes from the smear below, not from an isotropic estimate.
        let minification = textureRadius/max(f.radius,1)
        let blur = max(0, Int(((minification-1)/2).rounded(.up)))
        let channels=4
        // Separable box blur keeps work linear in patch area.
        let span = blur*2+1
        var horizontal = [Int](repeating: 0, count: raw.count)
        for y in 0..<textureSize { for channel in 0..<channels {
            var sum = (0...blur*2).reduce(0) { $0 + Int(raw[(y*textureSize+$1)*4+channel]) }
            for x in blur..<(textureSize-blur) {
                horizontal[(y*textureSize+x)*4+channel] = sum
                if x+blur+1 < textureSize {
                    sum += Int(raw[(y*textureSize+x+blur+1)*4+channel])
                        - Int(raw[(y*textureSize+x-blur)*4+channel])
                }
            }
        } }
        for x in blur..<(textureSize-blur) { for channel in 0..<channels {
            var sum = (0...blur*2).reduce(0) { $0 + horizontal[($1*textureSize+x)*4+channel] }
            for y in blur..<(textureSize-blur) {
                texture[(y*textureSize+x)*4+channel] = UInt8(sum/(span*span))
                if y+blur+1 < textureSize {
                    sum += horizontal[((y+blur+1)*textureSize+x)*4+channel]
                        - horizontal[((y-blur)*textureSize+x)*4+channel]
                }
            }
        } }
        // Always blur premultiplied colour and opacity together, then normalize.
        // This also protects sharp-source limbs, letting UVs reach the sphere's
        // curved edge without carrying transparent black into the material.
        for i in 0..<(textureSize*textureSize) {
            let alpha=Int(texture[i*4+3])
            if alpha>0 {for c in 0..<3 {texture[i*4+c]=UInt8(min(255,Int(texture[i*4+c])*255/alpha))}}
        }
        // Scene light from the real ball's white panels: the material's white is
        // rendered near 228, so scale each channel toward the photographed white.
        // Bounded so artistic skins keep their character.
        let gain: SIMD3<Double> = light.map { l in
            SIMD3(Double(l.x), Double(l.y), Double(l.z)).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))/228
        }.map { simd_clamp($0, SIMD3(repeating: 0.75), SIMD3(repeating: 1.15)) } ?? SIMD3(repeating: 1)
        // The material buffer is BGRA in memory: channel 0 is blue, 2 is red.
        let channelGain = [gain.z, gain.y, gain.x]
        var output = [UInt8](repeating: 0, count: dimension*dimension*4)
        let projection = SurfaceProjection(footprint:f)
        for y in 0..<dimension { for x in 0..<dimension {
            let dx = (Double(x)+0.5)*step-extent, dy = (Double(y)+0.5)*step-extent
            let alpha: Double
            if let coverage { alpha = coverage(f.center.x+dx, f.center.y+dy) }
            else {
                let distance = hypot(dx,dy), edge = f.edge(at:atan2(dy,dx))+f.padding
                let value = max(0,min(1,(edge-distance)/f.feather+0.5))
                alpha = value*value*(3-2*value)
            }
            guard alpha > 0 else { continue }
            // The same inverse projection applies everywhere on the ball.
            // Mask cutouts affect alpha only; they cannot stretch panel shapes.
            // During the exposure the print moves with the ball: average it along the smear.
            var colour = SIMD3<Double>(repeating: 0), samplesUsed = 0.0
            for step in 0..<smearSteps {
                let t = smearSteps == 1 ? 0 : (Double(step)+0.5)/Double(smearSteps)-0.5
                let uv = projection.point(x:f.center.x+dx-smear.dx*t,y:f.center.y+dy-smear.dy*t)
                let r = hypot(uv.x,uv.y)
                if smearSteps > 1 && r > 1.02 && samplesUsed+Double(smearSteps-step) > 1 { continue }
                let limit = min(1,0.995/max(r,0.0001))
                let tx = textureCenter + uv.x*textureRadius*limit
                let ty = textureCenter + uv.y*textureRadius*limit
                let ix = Int(tx), iy = Int(ty), fx = tx-Double(ix), fy = ty-Double(iy)
                for channel in 0..<3 {
                    func v(_ xx:Int,_ yy:Int)->Double { Double(texture[(yy*textureSize+xx)*4+channel]) }
                    let a = v(ix,iy)*(1-fx)+v(ix+1,iy)*fx
                    let b = v(ix,iy+1)*(1-fx)+v(ix+1,iy+1)*fx
                    colour[channel] += a*(1-fy)+b*fy
                }
                samplesUsed += 1
            }
            let offset = (y*dimension+x)*4
            for channel in 0..<3 {
                output[offset+channel] = UInt8(max(0,min(alpha*255,(colour[channel]/max(samplesUsed,1)*channelGain[channel]*alpha).rounded())))
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
    static func drawSkin(_ ctx: CGContext, center: CGPoint, radius: Double, skin: BallSkin, time: Double, orientation: simd_quatf? = nil) {
        guard radius > 0, let image = BallSkinSphereRenderer.image(skin: skin, time: time, orientation: orientation) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x-radius, y: center.y+radius)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x:0,y:0,width:radius*2,height:radius*2))
        ctx.restoreGState()
    }
}
