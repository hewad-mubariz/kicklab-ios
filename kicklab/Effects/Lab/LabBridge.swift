import CoreGraphics
import Foundation
import Metal
import simd

/// The Effects Lab work of 2026-11-19 in the app: 25 effects (the nine rebuilt to the concept sheet,
/// Origami Flight, Stormfront and the 14 Direction 02/03 effects) and 30 ball skins, drawn by the lab's
/// own renderers (Effects/Lab/Bridge, copied by the lab's scripts/fx/app-port.py) with their shaders in
/// separate fxlab-*.metallib files. Test build for the owner's phone; not reviewed for release.

/// One moment of a bridged effect: what the lab renderers need, built from the ball track.
nonisolated struct LabBridgeFrame: Sendable, Equatable {
    var style: BallStyle
    var time: Float
    var size: SIMD2<Float>
    var strength: Float
    var touches: [Float]
    var sample: @Sendable (Float) -> SIMD4<Float>

    static func == (a: Self, b: Self) -> Bool {
        a.style == b.style && a.time == b.time && a.size == b.size && a.strength == b.strength && a.touches == b.touches
    }
}

nonisolated extension BallStyle {
    /// Effects drawn through the lab bridge.
    static let bridged: [BallStyle] = [.inkBloom, .sakuraRush, .ferroStorm, .silkDancer, .bubbleBurst, .honeyDrift, .koiSpirit,
                                       .featherSweep, .riftBreak, .origamiFlight, .stormfront, .paintRiot, .solarShards, .vectorSlash,
                                       .victoryBurst, .coinRush, .slimePop, .toyBlast, .musicBounce, .popcornPop, .bubblegum,
                                       .discoFlash, .rubberRebound, .partyCannon, .starComet]
    var isBridged: Bool { Self.bridged.contains(self) }

    /// The lab Festival renderer's mode for the Direction 02/03 effects.
    var festivalMode: Int? {
        switch self {
        case .paintRiot: 0
        case .solarShards: 1
        case .vectorSlash: 2
        case .victoryBurst: 3
        case .coinRush: 5
        case .slimePop: 6
        case .toyBlast: 7
        case .musicBounce: 8
        case .popcornPop: 9
        case .bubblegum: 10
        case .discoFlash: 11
        case .rubberRebound: 12
        case .partyCannon: 13
        case .starComet: 14
        default: nil
        }
    }
}

/// Draws bridged effects. The lab renderers commit their own GPU work, so this runs synchronously:
/// the background must be finished before `render` is called.
nonisolated final class LabBridgeRenderer {
    private static let lock = NSLock()
    let kit: FXKit
    let queue: MTLCommandQueue
    private var effects: [BallStyle: FXEffect] = [:]

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(URL: try fxLabLibrary("fx"))
        guard let queue = device.makeCommandQueue() else { throw FXKit.failure("Command queue") }
        kit = FXKit(device: device, library: library)
        self.queue = queue
    }

    private func effect(_ style: BallStyle) throws -> FXEffect {
        if let made = effects[style] { return made }
        let made: FXEffect
        switch style {
        case .inkBloom: made = try InkFX(kit: kit)
        case .sakuraRush: made = try SakuraFX(kit: kit)
        case .ferroStorm: made = try FerroFX(kit: kit)
        case .silkDancer: made = try SilkFX(kit: kit)
        case .bubbleBurst: made = try BubbleFX(kit: kit)
        case .honeyDrift: made = try HoneyFX(kit: kit)
        case .koiSpirit: made = try KoiFX(kit: kit)
        case .featherSweep: made = try FeatherFX(kit: kit)
        case .riftBreak: made = try RiftFX(kit: kit)
        case .origamiFlight: made = try OrigamiFX(kit: kit)
        case .stormfront: made = try StormFX(kit: kit)
        default:
            guard let mode = style.festivalMode else { throw FXKit.failure("Not a lab effect: \(style.rawValue)") }
            made = try FestivalFX(kit: kit, mode: mode)
        }
        effects[style] = made
        return made
    }

    func render(_ frame: LabBridgeFrame, source: MTLTexture, target: MTLTexture) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let ctx = FXContext(time: frame.time, size: frame.size, intensity: frame.strength, touches: frame.touches, sample: frame.sample)
        guard let command = queue.makeCommandBuffer() else { throw FXKit.failure("Command buffer") }
        try effect(frame.style).encode(ctx, source: source, target: target, command: command)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }
}

nonisolated extension BallSkin {
    /// Ball skins drawn by the lab's skin renderers through the bridge.
    static let bridgedSkins: [BallSkin] = [.kintsugi, .porcelainTide, .dragonhide, .amberHive, .turboCore, .opalMosaic, .crimsonVelvet,
                                           .roseQuartz, .coralBloom, .meteorRelic, .apexCarbon, .redline, .monoShift, .ultraviolet,
                                           .chromeArmor, .plasmaCore, .aeroWhite, .scarletMesh, .topoOrange, .crownBlack, .discoMirror,
                                           .eightBall, .puzzleSphere, .gummyPop, .airPop, .toonBall, .littleEarth, .robotBuddy,
                                           .treasureOrb, .goalGlobe]
    var isBridgedSkin: Bool { Self.bridgedSkins.contains(self) }
}

/// The lab skins' balls as rasters, exactly like LabSkinRenderer.image: drawn over black with footage
/// lighting, then given the sphere's edge coverage as alpha.
nonisolated final class LabSkinBridge: @unchecked Sendable {
    static let shared = LabSkinBridge()
    private let lock = NSLock()
    private let device = MTLCreateSystemDefaultDevice()
    private var renderers: [BallSkin: (GoldUniforms, MTLTexture) throws -> Void] = [:]
    private var targets: [Int: MTLTexture] = [:]

    private func renderer(_ skin: BallSkin) throws -> (GoldUniforms, MTLTexture) throws -> Void {
        if let made = renderers[skin] { return made }
        func url(_ name: String) throws -> URL { try fxLabLibrary("skin-" + name) }
        let made: (GoldUniforms, MTLTexture) throws -> Void
        switch skin {
        case .kintsugi: let g = try KintsugiGPU(device: device, libraryURL: url("kintsugi")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .porcelainTide: let g = try PorcelainGPU(device: device, libraryURL: url("porcelain")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .dragonhide: let g = try DragonhideGPU(device: device, libraryURL: url("dragonhide")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .amberHive: let g = try AmberGPU(device: device, libraryURL: url("amber")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .turboCore: let g = try TurboGPU(device: device, libraryURL: url("turbo")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .opalMosaic: let g = try OpalGPU(device: device, libraryURL: url("opal")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .crimsonVelvet: let g = try VelvetGPU(device: device, libraryURL: url("velvet")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .roseQuartz: let g = try QuartzGPU(device: device, libraryURL: url("quartz")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .coralBloom: let g = try CoralGPU(device: device, libraryURL: url("coral")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .meteorRelic: let g = try MeteorGPU(device: device, libraryURL: url("meteor")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .apexCarbon: let g = try ApexGPU(device: device, libraryURL: url("apex")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .redline: let g = try RedlineGPU(device: device, libraryURL: url("redline")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .monoShift: let g = try MonoGPU(device: device, libraryURL: url("mono")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .ultraviolet: let g = try UltravioletGPU(device: device, libraryURL: url("ultraviolet")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .chromeArmor: let g = try ChromeGPU(device: device, libraryURL: url("chrome")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .plasmaCore: let g = try PlasmaGPU(device: device, libraryURL: url("plasma")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .aeroWhite: let g = try AeroGPU(device: device, libraryURL: url("aero")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .scarletMesh: let g = try ScarletGPU(device: device, libraryURL: url("scarlet")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .topoOrange: let g = try TopoGPU(device: device, libraryURL: url("topo")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .crownBlack: let g = try CrownGPU(device: device, libraryURL: url("crown")); made = { try g.render(frame: $0, source: nil, target: $1) }
        case .discoMirror: let g = try DiscoGPU(device: device, libraryURL: url("disco")); made = { try g.render(frame: $0, source: nil, target: $1) }
        default:
            let g = try ArcadeGPU(device: device, libraryURL: url("arcade")); made = { try g.render(frame: $0, source: nil, target: $1) }
        }
        renderers[skin] = made
        return made
    }

    private func uniforms(_ skin: BallSkin, size: Float, ball: SIMD4<Float>, pose: simd_quatf) -> GoldUniforms {
        let s = SIMD2(size, size)
        switch skin {
        case .kintsugi: return KintsugiScene.uniforms(skin: .kintsugi, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .porcelainTide: return PorcelainScene.uniforms(skin: .porcelain, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .dragonhide: return DragonhideScene.uniforms(skin: .dragonhide, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .amberHive: return AmberScene.uniforms(skin: .amber, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .turboCore: return TurboScene.uniforms(skin: .turbo, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .opalMosaic: return OpalScene.uniforms(skin: .opal, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .crimsonVelvet: return VelvetScene.uniforms(skin: .velvet, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .roseQuartz: return QuartzScene.uniforms(skin: .quartz, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .coralBloom: return CoralScene.uniforms(skin: .coral, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .meteorRelic: return MeteorScene.uniforms(skin: .meteor, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .apexCarbon: return ApexScene.uniforms(skin: .apex, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .redline: return RedlineScene.uniforms(skin: .redline, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .monoShift: return MonoScene.uniforms(skin: .mono, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .ultraviolet: return UltravioletScene.uniforms(skin: .ultraviolet, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .chromeArmor: return ChromeScene.uniforms(skin: .chrome, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .plasmaCore: return PlasmaScene.uniforms(skin: .plasma, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .aeroWhite: return AeroScene.uniforms(skin: .aero, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .scarletMesh: return ScarletScene.uniforms(skin: .scarlet, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .topoOrange: return TopoScene.uniforms(skin: .topo, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .crownBlack: return CrownScene.uniforms(skin: .crown, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .discoMirror: return DiscoScene.uniforms(skin: .disco, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .puzzleSphere: return ArcadeScene.uniforms(skin: .puzzle, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .gummyPop: return ArcadeScene.uniforms(skin: .gummy, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .airPop: return ArcadeScene.uniforms(skin: .air, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .toonBall: return ArcadeScene.uniforms(skin: .toon, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .littleEarth: return ArcadeScene.uniforms(skin: .earth, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .robotBuddy: return ArcadeScene.uniforms(skin: .robot, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .treasureOrb: return ArcadeScene.uniforms(skin: .treasure, time: 0, size: s, ball: ball, pose: pose, source: true)
        case .goalGlobe: return ArcadeScene.uniforms(skin: .goal, time: 0, size: s, ball: ball, pose: pose, source: true)
        default: return ArcadeScene.uniforms(skin: .eightBall, time: 0, size: s, ball: ball, pose: pose, source: true)
        }
    }

    func image(skin: BallSkin, orientation: simd_quatf, size: Int) -> CGImage? {
        guard skin.isBridgedSkin, size > 0, let device else { return nil }
        lock.lock(); defer { lock.unlock() }
        let target: MTLTexture
        if let existing = targets[size] { target = existing } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
            d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            guard let made = device.makeTexture(descriptor: d) else { return nil }
            targets[size] = made; target = made
        }
        let half = Float(size) / 2
        do {
            try renderer(skin)(uniforms(skin, size: Float(size), ball: SIMD4(half, half, half, 1), pose: simd_normalize(orientation)), target)
        } catch {
            return nil
        }
        var bgra = [UInt8](repeating: 0, count: size * size * 4)
        bgra.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let nx = (Float(x) + 0.5) / half - 1, ny = 1 - (Float(y) + 0.5) / half
            let edge = 1 - (nx * nx + ny * ny).squareRoot()
            guard edge > 0 else { continue }
            let t = min(1, edge * half), coverage = t * t * (3 - 2 * t)
            let i = (y * size + x) * 4, alpha = UInt8((coverage * 255).rounded())
            rgba[i] = min(alpha, bgra[i + 2]); rgba[i + 1] = min(alpha, bgra[i + 1]); rgba[i + 2] = min(alpha, bgra[i])
            rgba[i + 3] = alpha
        } }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Helpers the lab's Festival scene calls on its own LiquidScene (the app's copy has fewer).
nonisolated extension LiquidScene {
    static func hash(_ x: Float) -> Float { let v = sin(x * 127.1 + 311.7) * 43758.5453; return v - floor(v) }
    static func velocity(at t: Float, sample: (Float) -> SIMD4<Float>) -> SIMD2<Float> {
        let p = sample(t), q = sample(max(0, t - 0.025))
        return simd_clamp((SIMD2(p.x, p.y) - SIMD2(q.x, q.y)) / 0.025, SIMD2(repeating: -p.z * 24), SIMD2(repeating: p.z * 24))
    }
}
nonisolated enum LiquidFluid { static let lifetime: Float = 0.92 }
