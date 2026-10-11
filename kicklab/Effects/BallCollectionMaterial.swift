import CoreGraphics
import Foundation
import ImageIO
import simd

/// Object-space colour, seam and surface-normal maps for every replacement ball.
/// Prepared offline at 1024 × 512, then sampled by the shared sphere renderer.
/// RGB stores unlit colour; the fourth channel stores seam distance, not opacity.
nonisolated enum BallCollectionMaterial {
    struct Artwork {
        let rgba: [UInt8]
        /// Object-space surface normals. They rotate with the print, not the studio light.
        let normals: [UInt8]
    }

    static func artwork(skin: BallSkin, width: Int, height: Int,
                        panelSites: [SIMD3<Float>]) -> Artwork? {
        guard skin != .original else { return nil }
        #if os(macOS)
        let selected = ProcessInfo.processInfo.environment["JUGGLE_DUDE_BAKE_SKINS"]?.split(separator: ",").map(String.init)
        if ProcessInfo.processInfo.environment["JUGGLE_DUDE_BAKE_MATERIALS"] != nil,
           selected == nil || selected!.contains(skin.rawValue) {
            let artwork = makeArtwork(skin: skin, width: width, height: height, panelSites: panelSites)
            if let directory = ProcessInfo.processInfo.environment["JUGGLE_DUDE_BAKE_MATERIALS"], let artwork {
                let data = Data(artwork.rgba + artwork.normals)
                do {
                    let compressed = try (data as NSData).compressed(using: .lzfse) as Data
                    try compressed.write(to: URL(fileURLWithPath: directory).appendingPathComponent(skin.materialResource + ".jdmaterial"))
                } catch { preconditionFailure("Could not bake material: \(error)") }
            }
            return artwork
        }
        #endif
        var url = Bundle.main.url(forResource: skin.materialResource, withExtension: "jdmaterial")
            ?? Bundle.main.url(forResource: skin.materialResource, withExtension: "jdmaterial", subdirectory: "BallMaterials")
        #if os(macOS)
        if let directory = ProcessInfo.processInfo.environment["KICKLAB_BALL_MATERIALS_DIR"] {
            url = URL(fileURLWithPath: directory).appendingPathComponent(skin.materialResource + ".jdmaterial")
        }
        #endif
        guard let url, let compressed = NSData(contentsOf: url),
              let data = try? compressed.decompressed(using: .lzfse), data.length == width * height * 7 else { return nil }
        let bytes = [UInt8](data as Data), split = width * height * 4
        return Artwork(rgba: Array(bytes[..<split]), normals: Array(bytes[split...]))
    }

    #if os(macOS)
    /// Offline source generation is excluded from the iPhone binary.
    private static func makeArtwork(skin: BallSkin, width: Int, height: Int,
                                    panelSites: [SIMD3<Float>]) -> Artwork? {
        let tile = SurfaceTile(skin: skin)
        let print = PrintedSurface(skin: skin, width: width, height: height)
        if ![.metal, .lava, .pearl, .volt].contains(skin), print == nil { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var relief = [Float](repeating: 0, count: width * height)
        let largePanels = Array(panelSites.prefix(12))
        for y in 0..<height { for x in 0..<width {
            let longitude = (Float(x) + 0.5) / Float(width) * 2 * .pi - .pi
            let latitude = .pi / 2 - (Float(y) + 0.5) / Float(height) * .pi
            let n = SIMD3(sin(longitude) * cos(latitude), sin(latitude), cos(longitude) * cos(latitude))
            let rgb: SIMD3<Float>
            let gap: Float
            let elevation: Float
            switch skin {
            case .metal:
                let grain = noise(SIMD3((n.x + n.y * 0.4) * 18, (n.y - n.x * 0.4) * 320, n.z * 18))
                let tone = 0.84 + (grain - 0.5) * 0.18
                rgb = SIMD3(repeating: tone)
                gap = 0.1
                elevation = grain * 0.00065
            case .lava:
                let stone = tile?.sample(n, scale: 0.72).x ?? noise(n * 43) * 0.4
                let rock = noise(n * 17)
                let tone = 0.075 + stone * 0.82
                rgb = SIMD3(tone, tone * 0.97, tone * 0.94)
                let fractured = simd_normalize(n + SIMD3(noise(n * 19), noise(n * 21 + 4), noise(n * 23 + 7)) * 0.024)
                gap = max(0, panelGap(fractured, sites: panelSites) + (noise(n * 71) - 0.5) * 0.008)
                elevation = stone * 0.020 + rock * 0.010 + smooth(0.002, 0.045, gap) * 0.024
            case .pearl:
                let cloud = noise(n * 5)
                let blush = smooth(0.3, 0.8, cloud)
                let grain = noise(n * 170)
                rgb = SIMD3(0.96, 0.925 - blush * 0.07, 0.92 + blush * 0.04) * (0.97 + grain * 0.05)
                let curved = simd_normalize(n + SIMD3(sin(n.y * 4), sin(n.z * 4), sin(n.x * 4)) * 0.075)
                gap = panelGap(curved, sites: largePanels)
                elevation = smooth(0.002, 0.070, gap) * 0.019 + grain * 0.0008
            case .volt:
                let rubber = tile?.sample(n, scale: 1.25) ?? SIMD3<Float>(0.73, 0.9, 0.02)
                rgb = SIMD3(rubber.x * 0.98, rubber.y, rubber.z * 0.55)
                let curved = simd_normalize(n + SIMD3(sin(n.y * 3.2), sin(n.z * 3.2), sin(n.x * 3.2)) * 0.24)
                gap = panelGap(curved, sites: largePanels)
                elevation = rubber.y * 0.030 * smooth(0.018, 0.04, gap)
                    + smooth(0.017, 0.065, gap) * 0.015
            case .classic, .stealth, .matrix, .gold, .arctic, .crimson, .galaxy, .chrome, .graffiti, .aurora:
                // Preserve the existing print exactly. Ink colour must not become
                // fake mountains: relief comes from the material and panel shapes.
                rgb = print!.color(x: x, y: y)
                gap = panelGap(n, sites: panelSites)
                let fine = noise(n * 190), grain = noise(n * 95)
                let grainDepth: Float
                let panelDepth: Float
                switch skin {
                case .stealth: grainDepth = 0.0018; panelDepth = 0.013
                case .classic, .crimson, .graffiti, .aurora: grainDepth = 0.0016; panelDepth = 0.012
                case .matrix: grainDepth = 0.0010; panelDepth = 0.011
                case .arctic: grainDepth = 0.0009; panelDepth = 0.011
                case .gold, .chrome: grainDepth = 0.0005; panelDepth = 0.009
                case .galaxy: grainDepth = 0.00025; panelDepth = 0.008
                default: grainDepth = 0; panelDepth = 0
                }
                elevation = smooth(0.002, 0.045, gap) * panelDepth
                    + (fine * 0.65 + grain * 0.35) * grainDepth
            default: return nil
            }
            let index = (y * width + x) * 4
            for c in 0..<3 { bytes[index + c] = UInt8(max(0, min(255, (rgb[c] * 255).rounded()))) }
            bytes[index + 3] = UInt8((min(0.1, gap) * 2550).rounded())
            relief[y * width + x] = elevation
        } }
        var normals = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width {
            let longitude = (Float(x) + 0.5) / Float(width) * 2 * .pi - .pi
            let latitude = .pi / 2 - (Float(y) + 0.5) / Float(height) * .pi
            let sl = sin(longitude), cl = cos(longitude), sp = sin(latitude), cp = cos(latitude)
            let n = SIMD3(sl * cp, sp, cl * cp)
            let dx = (relief[y * width + (x + 1) % width] - relief[y * width + (x + width - 1) % width])
                / (4 * .pi / Float(width) * max(0.08, cp))
            let dy = (relief[max(0, y - 1) * width + x] - relief[min(height - 1, y + 1) * width + x])
                / (2 * .pi / Float(height))
            let tangent = SIMD3(cl, 0, -sl) * dx + SIMD3(-sl * sp, cp, -cl * sp) * dy
            let normal = simd_normalize(n - tangent * min(1, 0.7 / max(0.001, simd_length(tangent))))
            for c in 0..<3 { normals[(y * width + x) * 3 + c] = UInt8((max(0, min(1, normal[c] * 0.5 + 0.5)) * 255).rounded()) }
        } }
        return Artwork(rgba: bytes, normals: normals)
    }

    /// Decode the existing 2:1 print without inventing a new design or baked lighting.
    private struct PrintedSurface {
        let bytes: [UInt8]
        let width: Int
        init?(skin: BallSkin, width: Int, height: Int) {
            let environment = ProcessInfo.processInfo.environment
            guard let directory = environment["JUGGLE_DUDE_PRINT_SOURCES"]
                ?? environment["KICKLAB_BALL_MATERIALS_DIR"] else { return nil }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(skin.materialResource + ".jpg")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var data = Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
            let original = data, overlap = width / 32
            for y in 0..<height { for x in 0..<overlap {
                let blend = (1 - smooth(0, Float(overlap - 1), Float(x))) * 0.5
                let left = (y * width + x) * 4, right = (y * width + width - 1 - x) * 4
                for c in 0..<3 {
                    let a = Float(original[left+c]), b = Float(original[right+c])
                    data[left+c] = UInt8((a * (1-blend) + b * blend).rounded())
                    data[right+c] = UInt8((b * (1-blend) + a * blend).rounded())
                }
            } }
            self.width = width
            bytes = data
        }
        func color(x: Int, y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(bytes[i]), Float(bytes[i+1]), Float(bytes[i+2])) / 255
        }
    }

    /// Triplanar sampling keeps the generated surface grain free of polar stretching.
    /// Only map preparation samples the source photo; video frames use cached maps.
    private struct SurfaceTile {
        let bytes: [UInt8]
        let size = 512
        init?(skin: BallSkin) {
            guard skin == .lava || skin == .volt else { return nil }
            let name = "ball-surface-" + skin.rawValue
            var url = Bundle.main.url(forResource: name, withExtension: "jpg")
                ?? Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "BallMaterials")
            #if os(macOS)
            if let directory = ProcessInfo.processInfo.environment["JUGGLE_DUDE_SURFACE_SOURCES"] {
                url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".jpg")
            }
            #endif
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            bytes = Array(UnsafeBufferPointer(start: buffer, count: size * size * 4))
        }

        func sample(_ n: SIMD3<Float>, scale: Float) -> SIMD3<Float> {
            // Mirror repeat avoids a jump where a generated tile's edges differ.
            func read(_ u: Float, _ v: Float) -> SIMD3<Float> {
                func coordinate(_ value: Float) -> Float {
                    let t = value - floor(value / 2) * 2
                    return (t <= 1 ? t : 2 - t) * Float(size - 1)
                }
                let x = coordinate(u), y = coordinate(v), ix = Int(x), iy = Int(y)
                let fx = x - Float(ix), fy = y - Float(iy)
                func color(_ x: Int, _ y: Int) -> SIMD3<Float> {
                    let i = (y * size + x) * 4
                    return SIMD3(Float(bytes[i]), Float(bytes[i+1]), Float(bytes[i+2])) / 255
                }
                let x1 = min(size - 1, ix + 1), y1 = min(size - 1, iy + 1)
                return (color(ix, iy) * (1-fx) + color(x1, iy) * fx) * (1-fy)
                    + (color(ix, y1) * (1-fx) + color(x1, y1) * fx) * fy
            }
            var weight = SIMD3(pow(abs(n.x), 10), pow(abs(n.y), 10), pow(abs(n.z), 10))
            weight /= weight.x + weight.y + weight.z
            let p = n * scale + SIMD3<Float>(0.27, 0.51, 0.73)
            return read(p.y, p.z) * weight.x + read(p.x, p.z) * weight.y + read(p.x, p.y) * weight.z
        }
    }

    private static func panelGap(_ n: SIMD3<Float>, sites: [SIMD3<Float>]) -> Float {
        var first: Float = -2, second: Float = -2
        var nearest = SIMD3<Float>(0, 1, 0), next = nearest
        for site in sites {
            let distance = simd_dot(n, site)
            if distance > first { second = first; next = nearest; first = distance; nearest = site }
            else if distance > second { second = distance; next = site }
        }
        return (first - second) / max(0.01, simd_length(nearest - next))
    }

    private static func smooth(_ a: Float, _ b: Float, _ value: Float) -> Float {
        let t = max(0, min(1, (value - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374761393
        h = h &+ UInt32(bitPattern: y) &* 668265263 &+ UInt32(bitPattern: z) &* 2246822519
        h = (h ^ (h >> 13)) &* 1274126177
        return Float((h ^ (h >> 16)) & 65535) / 65535
    }

    /// Smooth deterministic 3D noise avoids a visible meridian or polar pinching.
    private static func noise(_ p: SIMD3<Float>) -> Float {
        let cell = SIMD3<Int32>(Int32(floor(p.x)), Int32(floor(p.y)), Int32(floor(p.z)))
        let f = p - SIMD3(Float(cell.x), Float(cell.y), Float(cell.z))
        let w = f * f * (3 - 2 * f)
        func row(_ y: Int32, _ z: Int32) -> Float {
            hash(cell.x, y, z) * (1 - w.x) + hash(cell.x + 1, y, z) * w.x
        }
        let a = row(cell.y, cell.z) * (1 - w.y) + row(cell.y + 1, cell.z) * w.y
        let b = row(cell.y, cell.z + 1) * (1 - w.y) + row(cell.y + 1, cell.z + 1) * w.y
        return a * (1 - w.z) + b * w.z
    }
    #endif
}
