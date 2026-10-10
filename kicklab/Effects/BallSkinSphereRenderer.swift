import CoreGraphics
import Foundation
import ImageIO
import simd

/// One lit sphere and shared panel topology, with ten printed material maps.
/// Raster work stays ball-sized. No scene graph, extra detector or video masks.
nonisolated enum BallSkinSphereRenderer {
    private static let width = 512, height = 256
    private static let rasterSize = 192
    /// Interface size for quick spins: about half the pixels, same print, light and rotation.
    private static let previewRaster = 144
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    private struct Texture: Sendable {
        let rgba: [UInt8]
    }
    private final class ImageCache: @unchecked Sendable {
        let images = NSCache<NSString, CGImage>()
        init() { images.totalCostLimit = 2*1024*1024; images.countLimit = 12 }
    }
    private static let cache = ImageCache()
    // Decoded artwork is fixed at 5 MiB for all ten styles, independent of video
    // duration. Bundle resources are the same in the picker, replay and export.
    private static let textures: [BallSkin: Texture] = {
        var result: [BallSkin: Texture] = [:]
        for skin in BallSkin.allCases where skin != .original {
            guard let url = resourceURL(skin),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width*4, space: colorSpace, bitmapInfo: bitmapInfo),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var rgba = Array(UnsafeBufferPointer(start: bytes, count: width*height*4))
            // Seal the narrow UV join; generated print artwork is not guaranteed
            // to have numerically identical first/last columns.
            let original = rgba, overlap = width/32
            for y in 0..<height { for x in 0..<overlap {
                let blend = (1-smooth(0,Float(overlap-1),Float(x)))*0.5
                let left = (y*width+x)*4, right = (y*width+width-1-x)*4
                for c in 0..<3 {
                    let a = Float(original[left+c]), b = Float(original[right+c])
                    rgba[left+c] = UInt8((a*(1-blend)+b*blend).rounded())
                    rgba[right+c] = UInt8((b*(1-blend)+a*blend).rounded())
                }
            } }
            result[skin] = Texture(rgba: rgba)
        }
        return result
    }()

    private static func resourceURL(_ skin: BallSkin) -> URL? {
        #if os(macOS)
        // Standalone production-renderer audit; iOS only reads bundled assets.
        if let directory = ProcessInfo.processInfo.environment["KICKLAB_BALL_MATERIALS_DIR"] {
            return URL(fileURLWithPath: directory).appendingPathComponent(skin.materialResource + ".jpg")
        }
        #endif
        return Bundle.main.url(forResource: skin.materialResource, withExtension: "jpg")
            ?? Bundle.main.url(forResource: skin.materialResource, withExtension: "jpg", subdirectory: "BallMaterials")
    }

    static func hasArtwork(for skin: BallSkin) -> Bool { textures[skin] != nil }
    static var decodedArtworkBytes: Int { textures.values.reduce(0) { $0+$1.rgba.count } }

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

    private static let grooves: [Float] = {
        var data = [Float](repeating: 0, count: width*height)
        for y in 0..<height { for x in 0..<width {
            let theta = (Float(x)+0.5)/Float(width)*2 * .pi - .pi
            let phi = .pi/2 - (Float(y)+0.5)/Float(height) * .pi
            let n = SIMD3(sin(theta)*cos(phi), sin(phi), cos(theta)*cos(phi))
            var first: Float = -2, second: Float = -2
            var i1 = 0, i2 = 0
            for (index,site) in panelSites.enumerated() {
                let d = simd_dot(n,site)
                if d > first { second=first; i2=i1; first=d; i1=index }
                else if d > second { second=d; i2=index }
            }
            data[y*width+x] = (first-second)/max(0.01,simd_length(panelSites[i1]-panelSites[i2]))
        } }
        return data
    }()

    private struct Pixel: Sendable {
        let offset: Int
        let normal: SIMD3<Float>
        let alpha: Float
        let diffuse: Float
        let softDiffuse: Float
        let broadSpecular: Float
        let narrowSpecular: Float
        // View-space lighting is fixed for every pose; calculate it once.
        let rim: Float
    }
    private static let pixels = makePixels(rasterSize)
    private static let previewPixels = makePixels(previewRaster)

    private static func makePixels(_ rasterSize: Int) -> [Pixel] {
        let light = simd_normalize(SIMD3<Float>(-0.5,0.7,1.1))
        let half = simd_normalize(light+SIMD3<Float>(0,0,1))
        let secondaryHalf = simd_normalize(SIMD3<Float>(0.65,0.3,1.8))
        let softLight = simd_normalize(SIMD3<Float>(-0.28,0.48,0.832))
        var result = [Pixel](); result.reserveCapacity(rasterSize*rasterSize)
        for y in 0..<rasterSize { for x in 0..<rasterSize {
            let nx = (Float(x)+0.5)/Float(rasterSize)*2-1
            let ny = 1-(Float(y)+0.5)/Float(rasterSize)*2
            let rr = nx*nx+ny*ny
            guard rr < 1 else { continue }
            let n = SIMD3(nx,ny,sqrt(max(0,1-rr)))
            let alpha = min(1,(1-sqrt(rr))*Float(rasterSize)*0.5)
            let lambert = max(0,simd_dot(n,light))
            result.append(Pixel(offset:(y*rasterSize+x)*4,normal:n,alpha:alpha,
                diffuse:0.38+0.62*lambert,
                softDiffuse:0.20+0.72*max(0,simd_dot(n,softLight))+0.08*n.z,
                broadSpecular:pow(max(0,simd_dot(n,half)),28),
                narrowSpecular:pow(max(0,simd_dot(n,secondaryHalf)),100),
                rim:pow(1-n.z,4)))
        } }
        return result
    }

    static func image(skin: BallSkin, time: Double, orientation: simd_quatf? = nil) -> CGImage? {
        render(skin: skin, time: time, rasterSize: rasterSize, pixels: pixels, cached: true, orientation: orientation)
    }

    /// Picker-size frame for animated spins. Not cached: a spin is a one-off run of poses.
    static func previewImage(skin: BallSkin, time: Double, orientation: simd_quatf? = nil) -> CGImage? {
        render(skin: skin, time: time, rasterSize: previewRaster, pixels: previewPixels, cached: false,
               orientation: orientation)
    }

    private static func render(skin: BallSkin, time: Double, rasterSize: Int, pixels: [Pixel], cached: Bool, orientation: simd_quatf? = nil) -> CGImage? {
        guard skin != .original, time.isFinite, let texture = textures[skin] else { return nil }
        // Deterministic video-time rotation. This is an art animation, not an
        // estimate of the real football's angular velocity.
        let tick = Int64((max(0,min(time,1e7))*60).rounded())
        let poseKey = orientation.map { q in [q.vector.x,q.vector.y,q.vector.z,q.vector.w].map { String($0.bitPattern) }.joined(separator: ":") } ?? "timer:\(tick)"
        let key = "\(skin.rawValue):\(poseKey)" as NSString
        if cached, let image = cache.images.object(forKey:key) { return image }
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
            let gap = grooves[i00]*w00+grooves[i10]*w10+grooves[i01]*w01+grooves[i11]*w11
            let groove = 1-smooth(0.002,0.010,gap)
            let bevel = exp(-pow((gap-0.013)/0.005,2))*0.045
            let luminance = simd_dot(rgb,SIMD3<Float>(0.2126,0.7152,0.0722))
            let gold = skin == .gold ? smooth(0.10,0.38,rgb.x-rgb.z) : 0
            let metallic: Float = skin == .chrome ? 0.48 : gold*0.78
            let rough: Float = skin == .stealth ? 0.94 : (skin == .galaxy ? 0.32 : 0.68-metallic*0.4)
            let spec = (pixel.broadSpecular*(0.12+metallic*0.3)*(1-rough*0.4)
                + pixel.narrowSpecular*(0.08+metallic*0.38)*(1-rough*0.7)) * (skin == .galaxy ? 0.5 : 1)
            // Galaxy's print supplies its colour. A bright white rim made it
            // read as a luminous disc; keep a softer material highlight instead.
            let rim = pixel.rim*(skin == .stealth ? 0.075 : (skin == .galaxy ? 0.0042 : 0.035))
            let emission: Float = skin == .matrix ? max(0,rgb.y-max(rgb.x,rgb.z))*0.18
                : (skin == .galaxy ? max(0,luminance-0.45)*0.15 : 0)
            // Lighting is fixed in view space while the print and grooves rotate.
            let diffuse = skin == .galaxy ? pixel.softDiffuse : pixel.diffuse
            let linear = rgb*rgb*(diffuse*(1-groove*0.70)+bevel+emission)
            let highlight = SIMD3<Float>(1,1,1)*(spec*(1-metallic*0.65)+rim)
                + rgb*(spec*metallic*0.65)
            let shaded = linear+highlight*(1-groove*0.7)
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

    private static func smooth(_ low: Float,_ high: Float,_ value: Float) -> Float {
        let t = max(0,min(1,(value-low)/(high-low)))
        return t*t*(3-2*t)
    }
}
