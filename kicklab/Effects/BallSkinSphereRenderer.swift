import CoreGraphics
import Foundation
import simd

/// One lit sphere with shared or material-specific seams and lighting.
/// Raster work stays ball-sized. No scene graph, extra detector or video masks.
nonisolated enum BallSkinSphereRenderer {
    private static let width = 1024, height = 512
    private static let rasterSize = 256
    /// Interface size for quick spins: about half the pixels, same print, light and rotation.
    private static let previewRaster = 144
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    private struct Texture: Sendable {
        let rgba: [UInt8]
        let normals: [UInt8]
    }
    private final class ImageCache: @unchecked Sendable {
        let images = NSCache<NSString, CGImage>()
        init() { images.totalCostLimit = 2*1024*1024; images.countLimit = 12 }
    }
    private static let cache = ImageCache()
    /// Bound decoded material retention as the catalogue grows. The picker keeps
    /// its rendered thumbnail; only four recently used 3.5 MiB maps stay resident.
    private final class MaterialCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [BallSkin: Texture] = [:]
        private var order: [BallSkin] = []
        func texture(for skin: BallSkin) -> Texture? {
            guard skin != .original else { return nil }
            lock.lock(); defer { lock.unlock() }
            if let value = values[skin] {
                order.removeAll { $0 == skin }; order.append(skin)
                return value
            }
            guard let artwork = BallCollectionMaterial.artwork(skin: skin, width: width, height: height, panelSites: panelSites) else { return nil }
            let value = Texture(rgba: artwork.rgba, normals: artwork.normals)
            if order.count == 4 { values.removeValue(forKey: order.removeFirst()) }
            values[skin] = value; order.append(skin)
            return value
        }
        var byteCount: Int {
            lock.lock(); defer { lock.unlock() }
            return values.values.reduce(0) { $0 + $1.rgba.count + $1.normals.count }
        }
    }
    private static let materials = MaterialCache()

    static func hasArtwork(for skin: BallSkin) -> Bool { materials.texture(for: skin) != nil }
    static var decodedArtworkBytes: Int { materials.byteCount }

    // Dual of a truncated icosahedron: twelve pentagonal and twenty hexagonal
    // spherical panels. Printed artwork crosses panels; recessed seams are shared.
    private static let panelSites: [SIMD3<Float>] = {
        let phi = Float((1+sqrt(5.0))/2)
        var vertices = [SIMD3<Float>]()
        for a: Float in [-1,1] { for b in [-phi,phi] {
            vertices += [SIMD3(0,a,b),SIMD3(a,b,0),SIMD3(b,0,a)]
        } }
        var sites = vertices.map(simd_normalize)
        for i in 0..<vertices.count { for j in (i+1)..<vertices.count { for k in (j+1)..<vertices.count {
            if abs(simd_length(vertices[i]-vertices[j])-2)<0.001,
               abs(simd_length(vertices[i]-vertices[k])-2)<0.001,
               abs(simd_length(vertices[j]-vertices[k])-2)<0.001 {
                sites.append(simd_normalize(vertices[i]+vertices[j]+vertices[k]))
            }
        } } }
        return sites
    }()

    private struct Pixel: Sendable {
        let offset: Int
        let normal: SIMD3<Float>
        let alpha: Float
        let narrowSpecular: Float
        // View-space lighting is fixed for every pose; calculate it once.
        let rim: Float
    }
    private static let pixels = makePixels(rasterSize)
    private static let previewPixels = makePixels(previewRaster)

    private static func makePixels(_ rasterSize: Int) -> [Pixel] {
        let secondaryHalf = simd_normalize(SIMD3<Float>(0.65,0.3,1.8))
        var result = [Pixel](); result.reserveCapacity(rasterSize*rasterSize)
        for y in 0..<rasterSize { for x in 0..<rasterSize {
            let nx = (Float(x)+0.5)/Float(rasterSize)*2-1
            let ny = 1-(Float(y)+0.5)/Float(rasterSize)*2
            let rr = nx*nx+ny*ny
            guard rr < 1 else { continue }
            let n = SIMD3(nx,ny,sqrt(max(0,1-rr)))
            let alpha = min(1,(1-sqrt(rr))*Float(rasterSize)*0.5)
            result.append(Pixel(offset:(y*rasterSize+x)*4,normal:n,alpha:alpha,
                narrowSpecular:pow(max(0,simd_dot(n,secondaryHalf)),100),
                rim:pow(1-n.z,4)))
        } }
        return result
    }

    static func image(skin: BallSkin, time: Double, orientation: simd_quatf? = nil) -> CGImage? {
        render(skin: skin, time: time, rasterSize: rasterSize, pixels: pixels, cached: true, orientation: orientation)
    }

    static func rasterDimension(for _: BallSkin) -> Int {
        rasterSize
    }

    /// Picker-size frame for animated spins. Not cached: a spin is a one-off run of poses.
    static func previewImage(skin: BallSkin, time: Double, orientation: simd_quatf? = nil) -> CGImage? {
        render(skin: skin, time: time, rasterSize: previewRaster, pixels: previewPixels, cached: false,
               orientation: orientation)
    }

    private static func render(skin: BallSkin, time: Double, rasterSize: Int, pixels: [Pixel], cached: Bool, orientation: simd_quatf? = nil) -> CGImage? {
        guard skin != .original, time.isFinite else { return nil }
        // Deterministic video-time rotation. This is an art animation, not an
        // estimate of the real football's angular velocity.
        let tick = Int64((max(0,min(time,1e7))*60).rounded())
        let poseKey = orientation.map { q in [q.vector.x,q.vector.y,q.vector.z,q.vector.w].map { String($0.bitPattern) }.joined(separator: ":") } ?? "timer:\(tick)"
        let key = "\(skin.rawValue):\(poseKey)" as NSString
        if cached, let image = cache.images.object(forKey:key) { return image }
        guard let texture = materials.texture(for: skin) else { return nil }
        let t = Float(Double(tick)/60)
        let yaw = t*1.1+0.35, pitch = t*0.29+0.18
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        // A source-driven pose uses the same inverse for every sphere pixel.
        let inverseOrientation = orientation?.inverse
        var rgba = [UInt8](repeating:0,count:rasterSize*rasterSize*4)
        for pixel in pixels {
            let n = pixel.normal
            let object: SIMD3<Float>
            if let inverseOrientation {
                object = inverseOrientation.act(n)
            } else {
                let rotatedY = SIMD3(n.x*cy-n.z*sy,n.y,n.x*sy+n.z*cy)
                object = SIMD3(rotatedY.x, rotatedY.y*cp+rotatedY.z*sp, -rotatedY.y*sp+rotatedY.z*cp)
            }
            let u = (atan2(object.x,object.z)/(2 * .pi)+0.5)*Float(width)-0.5
            let v = max(0,min(Float(height-1), (0.5-asin(max(-1,min(1,object.y))) / .pi)*Float(height)-0.5))
            let bx = Int(floor(u)), by = Int(v)
            let x0 = (bx+width)%width, x1 = (x0+1)%width, y1 = min(height-1,by+1)
            let fx = u-Float(bx), fy = v-Float(by)
            let i00 = by*width+x0, i10 = by*width+x1, i01 = y1*width+x0, i11 = y1*width+x1
            let w00 = (1-fx)*(1-fy), w10 = fx*(1-fy), w01 = (1-fx)*fy, w11 = fx*fy
            func color(_ i: Int) -> SIMD3<Float> {
                let p = i*4
                return SIMD3(Float(texture.rgba[p]),Float(texture.rgba[p+1]),Float(texture.rgba[p+2]))/255
            }
            let rgb = color(i00)*w00+color(i10)*w10+color(i01)*w01+color(i11)*w11
            func seam(_ i: Int) -> Float { Float(texture.rgba[i * 4 + 3]) / 2550 }
            let gap = seam(i00)*w00 + seam(i10)*w10 + seam(i01)*w01 + seam(i11)*w11
            func surfaceNormal(_ i: Int) -> SIMD3<Float> {
                let p = i * 3
                return SIMD3(Float(texture.normals[p]), Float(texture.normals[p+1]), Float(texture.normals[p+2])) / 127.5 - 1
            }
            let bump = simd_normalize(surfaceNormal(i00)*w00 + surfaceNormal(i10)*w10
                + surfaceNormal(i01)*w01 + surfaceNormal(i11)*w11)
            let litNormal: SIMD3<Float>
            if let orientation { litNormal = orientation.act(bump) }
            else {
                let unpitched = SIMD3(bump.x, bump.y*cp-bump.z*sp, bump.y*sp+bump.z*cp)
                litNormal = SIMD3(unpitched.x*cy+unpitched.z*sy, unpitched.y, -unpitched.x*sy+unpitched.z*cy)
            }
            let shaded = collectionShade(skin: skin, rgb: rgb, gap: gap, normal: litNormal, pixel: pixel)
            for c in 0..<3 { rgba[pixel.offset+c] = UInt8(max(0,min(255,(min(1,sqrt(max(0,shaded[c])))*pixel.alpha*255).rounded()))) }
            rgba[pixel.offset+3] = UInt8((pixel.alpha*255).rounded())
        }
        guard let provider = CGDataProvider(data:Data(rgba) as CFData),
              let image = CGImage(width:rasterSize,height:rasterSize,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:rasterSize*4,space:colorSpace,bitmapInfo:CGBitmapInfo(rawValue:bitmapInfo),
                provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
        if cached { cache.images.setObject(image,forKey:key,cost:rgba.count) }
        return image
    }

    /// Surface relief rotates with the ball. Soft studio lighting stays in view space.
    private static func collectionShade(skin: BallSkin, rgb: SIMD3<Float>, gap: Float,
                                        normal: SIMD3<Float>, pixel: Pixel) -> SIMD3<Float> {
        let light = SIMD3<Float>(-0.45, 0.65, 0.612372)
        let half = simd_normalize(light + SIMD3<Float>(0, 0, 1))
        let diffuse = 0.16 + 0.84 * max(0, simd_dot(normal, light))
        let specular = pow(max(0, simd_dot(normal, half)), 32)
        switch skin {
        case .metal:
            return rgb * rgb * steelEnvironment(normal) + SIMD3(repeating: pixel.rim * 0.16)
        case .lava:
            let crack = 1 - smooth(0.003, 0.013, gap)
            let glow = 1 - smooth(0.008, 0.036, gap)
            let rock = rgb * rgb * diffuse * (1 - crack * 0.9)
            let hot = SIMD3<Float>(1.4, 0.24, 0.008) * crack
                + SIMD3<Float>(0.42, 0.045, 0.002) * glow
            return rock + hot + SIMD3(repeating: specular * 0.07 * (1 - glow))
        case .pearl:
            let groove = 1 - smooth(0.002, 0.014, gap)
            let bevel = exp(-pow((gap - 0.019) / 0.008, 2)) * 0.065
            let glint = specular * 0.35 + pixel.narrowSpecular * 0.06
            let pearlescence = SIMD3<Float>(0.045, 0.025, 0.06) * pow(1 - pixel.normal.z, 1.3)
            return rgb * rgb * ((0.24 + diffuse * 0.76) * (1 - groove * 0.5) + bevel)
                + SIMD3(repeating: glint + pixel.rim * 0.045) + pearlescence
        case .volt:
            let groove = 1 - smooth(0.018, 0.030, gap)
            let bevel = exp(-pow((gap - 0.040) / 0.009, 2)) * 0.075
            let rubber = rgb * rgb * (1 - groove) + SIMD3<Float>(0.016, 0.023, 0.013) * groove
            return rubber * (0.14 + diffuse * 0.86) + rgb * bevel
                + SIMD3(repeating: specular * 0.065 + pixel.rim * 0.012)
        case .classic, .stealth, .matrix, .gold, .arctic, .crimson, .galaxy, .chrome, .graffiti, .aurora:
            return printedShade(skin: skin, rgb: rgb, gap: gap, normal: normal, pixel: pixel)
        case .original: return .zero
        }
    }

    /// Original catalogue prints retain their colours. Relief and finish are
    /// independent of ink brightness, so a white logo does not become a raised lump.
    private static func printedShade(skin: BallSkin, rgb: SIMD3<Float>, gap: Float,
                                     normal: SIMD3<Float>, pixel: Pixel) -> SIMD3<Float> {
        let light = SIMD3<Float>(-0.45, 0.65, 0.612372)
        let half = simd_normalize(light + SIMD3<Float>(0, 0, 1))
        let lambert = max(0, simd_dot(normal, light))
        let highlight = pow(max(0, simd_dot(normal, half)), 36)
        let groove = 1 - smooth(0.002, 0.011, gap)
        let bevel = exp(-pow((gap - 0.015) / 0.007, 2)) * 0.025
        let metallic: Float = skin == .chrome ? 0.8 : (skin == .gold ? smooth(0.10, 0.38, rgb.x - rgb.z) * 0.85 : 0)
        var diffuse = 0.30 + 0.70 * lambert
        var specular: Float = 0.065, rim: Float = 0.018
        var emission: Float = 0
        switch skin {
        case .stealth: specular = 0.014; rim = 0.030
        case .matrix:
            specular = 0.045
            emission = max(0, rgb.y - max(rgb.x, rgb.z)) * 0.14
        case .gold, .chrome: specular = 0.10
        case .arctic: specular = 0.14; rim = 0.026
        case .galaxy:
            // Keep the previously tuned dark space print; no luminous white rim.
            diffuse = 0.20 + 0.72 * max(0, simd_dot(normal, simd_normalize(SIMD3<Float>(-0.28, 0.48, 0.832)))) + 0.08 * pixel.normal.z
            specular = 0.035; rim = 0.0042
            emission = max(0, simd_dot(rgb, SIMD3<Float>(0.2126, 0.7152, 0.0722)) - 0.45) * 0.15
        case .aurora: specular = 0.095
        default: break
        }
        let lighting = metallic > 0 ? diffuse * (1 - metallic * 0.65) + steelEnvironment(normal) * metallic * 0.65 : diffuse
        let surface = rgb * rgb * ((lighting + emission) * (1 - groove * 0.60) + bevel)
        let reflectionTint = SIMD3<Float>(repeating: 1 - metallic * 0.5) + rgb * metallic * 0.5
        return surface + reflectionTint * (highlight * specular + pixel.rim * rim) * (1 - groove * 0.75)
    }

    private static func steelEnvironment(_ normal: SIMD3<Float>) -> Float {
        let reflection = 2 * normal.z * normal - SIMD3<Float>(0, 0, 1)
        let key = pow(max(0, simd_dot(reflection, simd_normalize(SIMD3<Float>(-0.7, 0.7, 0.35)))), 5)
        let fill = pow(max(0, simd_dot(reflection, simd_normalize(SIMD3<Float>(0.9, 0.25, 0.1)))), 7)
        let edge = pow(max(0, simd_dot(reflection, simd_normalize(SIMD3<Float>(-0.9, -0.15, -0.2)))), 12)
        return 0.055 + smooth(-0.6, 0.9, reflection.y) * 0.17 + key * 1.65 + fill * 1.15 + edge * 0.8
    }

    private static func smooth(_ low: Float,_ high: Float,_ value: Float) -> Float {
        let t = max(0,min(1,(value-low)/(high-low)))
        return t*t*(3-2*t)
    }
}
