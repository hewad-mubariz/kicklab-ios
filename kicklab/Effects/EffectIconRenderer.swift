import CoreGraphics
import Foundation
import Metal
import simd

/// Picker icons: one football mid-flight with its effect trailing behind, drawn by
/// the same Metal pass as replay and export onto a transparent background.
/// No artwork to keep in sync; an icon is what the effect actually renders.
nonisolated enum EffectIconRenderer {
    /// Icon shape, wider than tall so the trail has room behind the ball.
    static let aspect: CGFloat = 4.0 / 3.0

    /// Renders at `height` pixels. `ball` is drawn over the effect; pass nil for the effect alone.
    static func image(shaderStyle: Float, height: Int, ball: CGImage?, engine: MetalEffectEngine,
                      time: Double = 2.35) throws -> CGImage? {
        let h = max(16, height), w = Int((CGFloat(h) * aspect).rounded())
        let radius = Float(h) * 0.16
        // Heat Pulse shows just after a touch, with the ball held still so the rings sit around it.
        let pulse = shaderStyle == 16
        let center = pulse ? SIMD2(Float(w) * 0.5, Float(h) * 0.5) : SIMD2(Float(w) * 0.6, Float(h) * 0.46)
        var effect: CGImage?
        if shaderStyle > 0.5 {
            let target = try engine.texture(width: w, height: h, storage: .shared)
            // Driven up and to the right: fast enough that trails stream behind the ball.
            let velocity = pulse ? SIMD2<Float>(0, 0) : SIMD2<Float>(12, -5)
            let trail: [SIMD4<Float>] = (1...32).map { index in
                let age = Float(index) / 40
                let p = pulse ? center : center - velocity * radius * age + SIMD2(0, radius * 1.6 * age * age)
                return SIMD4(p.x, p.y, radius, age)
            }
            var frame = EffectFrame(size: CGSize(width: w, height: h), center: center, radius: radius, time: time,
                                    intensity: 0.85, velocity: velocity,
                                    impact: shaderStyle == 16 ? 1 : 0,
                                    impactAge: shaderStyle == 16 ? 0.16 : -1,
                                    style: shaderStyle, trail: trail)
            if shaderStyle == BallStyle.liquid.shaderID {
                // One fresh splash along the same flight, over a plain grey the liquid can refract.
                WaterCrown.prepareAll()
                let path: (Float) -> SIMD4<Float> = { t in
                    let age = Float(time) - t
                    let p = center - velocity * radius * age + SIMD2(0, radius * 1.6 * age * age)
                    return SIMD4(p.x, p.y, radius, 1)
                }
                var liquid = LiquidScene.frame(time: Float(time), size: SIMD2(Float(w), Float(h)), intensity: 1,
                                               touches: [Float(time) - 0.20], sample: path)
                liquid.uniforms.options.y = -1; liquid.uniforms.options.w = 0.52
                frame.liquid = liquid
            }
            if shaderStyle == BallStyle.water.shaderID || shaderStyle == BallStyle.crystal.shaderID {
                // Water and Crystal draw over the picture they refract. Drawn once over black and once
                // over white, the difference is their transparency and the black render their colour.
                let path: (Float) -> SIMD4<Float> = { t in
                    let age = Float(time) - t
                    let p = center - velocity * radius * age + SIMD2(0, radius * 1.6 * age * age)
                    return SIMD4(p.x, p.y, radius, 1)
                }
                if shaderStyle == BallStyle.water.shaderID {
                    WaterCrown.prepareAll()
                    frame.water = WaterScene.frame(time: Float(time), size: SIMD2(Float(w), Float(h)), stage: .motion, intensity: 1,
                                                   light: true, source: true, touches: [Float(time) - 0.16], sample: path)
                } else {
                    frame.crystal = CrystalFrame.make(time: time, size: CGSize(width: w, height: h), strength: 1,
                                                      track: CrystalTrack(sample: path, touchTimes: [time - 0.18]))
                }
                frame.labBackdrop = 0
                try engine.render(frame, into: target)
                let black = pixels(of: target)
                frame.labBackdrop = 1
                try engine.render(frame, into: target)
                let white = pixels(of: target)
                // Clear water needs a boost to read on the tile; Crystal's mist and ice already do.
                effect = matte(black: black, white: white, width: w, height: h,
                               boost: shaderStyle == BallStyle.water.shaderID ? 4 : 1)
            } else {
                try engine.render(frame, into: target)
                effect = image(from: target)
            }
        }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        if let effect {
            // Feather the edges so wide effects fade out instead of being cut by the tile.
            context.saveGState()
            if let mask = edgeMask(width: w, height: h) { context.clip(to: bounds, mask: mask) }
            context.draw(effect, in: bounds)
            context.restoreGState()
        }
        if let ball {
            // Core Graphics is bottom-up; the effect frame is top-down.
            let r = CGFloat(radius) * 1.04
            context.draw(ball, in: CGRect(x: CGFloat(center.x) - r, y: CGFloat(h) - CGFloat(center.y) - r,
                                          width: r * 2, height: r * 2))
        }
        return context.makeImage()
    }

    /// White in the middle, fading to black over the outer fifth of each side.
    private static func edgeMask(width: Int, height: Int) -> CGImage? {
        func fade(_ t: Float) -> Float {
            let x = min(1, max(0, t / 0.2))
            return x * x * (3 - 2 * x)
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let v = Float(y) / Float(height - 1)
            let fy = fade(v) * fade(1 - v)
            for x in 0..<width {
                let u = Float(x) / Float(width - 1)
                bytes[y * width + x] = UInt8((fade(u) * fade(1 - u) * fy * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func pixels(of texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    /// Premultiplied pixels from renders over black and white: what the white backdrop adds is
    /// what shows through, so opacity is one minus that, and the black render is the colour. Clear
    /// water barely shows over a plain tile, so `boost` strengthens both for the icon.
    private static func matte(black: [UInt8], white: [UInt8], width: Int, height: Int, boost: Int = 4) -> CGImage? {
        var bytes = black
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let through = (0..<3).reduce(0) { $0 + max(0, Int(white[i + $1]) - Int(black[i + $1])) } / 3
            let alpha = min(255, (255 - min(255, through)) * boost)
            for c in 0..<3 { bytes[i + c] = UInt8(min(alpha, Int(black[i + c]) * boost)) }
            bytes[i + 3] = UInt8(alpha)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func image(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
