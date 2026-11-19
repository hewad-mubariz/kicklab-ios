// Copied from the Effects Lab (EffectLab/FX/LabSceneFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// The Direction 02/03 effects (15, one Festival renderer), Stormfront revision 2 and Origami Flight,
/// as FX effects so the lab harness and the app draw them the same way. Their lab renderers commit
/// their own GPU work, so the caller's command buffer stays empty.
nonisolated final class FestivalFX: FXEffect {
    /// Festival effect ids (scripts/festival/effects.json).
    static let names = ["Paint Riot", "Solar Shards", "Vector Slash", "Victory Burst", "Stormfront", "Coin Rush", "Slime Pop",
                        "Toy Blast", "Music Bounce", "Popcorn Pop", "Bubblegum", "Disco Flash", "Rubber Rebound", "Party Cannon", "Star Comet"]
    nonisolated(unsafe) private static var sharedGPU: FestivalGPU?
    private static let lock = NSLock()
    let gpu: FestivalGPU
    let mode: Int
    init(kit: FXKit) throws { throw FXKit.failure("Use init(kit:mode:)") }
    init(kit: FXKit, mode: Int) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let shared = Self.sharedGPU { gpu = shared } else {
            let made = try FestivalGPU(libraryURL: try fxLabLibrary("festival"))
            Self.sharedGPU = made; gpu = made
        }
        self.mode = mode
    }
    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let frame = FestivalScene.frame(time: ctx.time, size: ctx.size, mode: mode, intensity: ctx.intensity, touches: ctx.touches, sample: ctx.sample)
        try gpu.render(frame: frame, source: source, target: target)
    }
}

nonisolated final class StormFX: FXEffect {
    let gpu: StormGPU
    init(kit: FXKit) throws { gpu = try StormGPU(libraryURL: try fxLabLibrary("storm")) }
    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let frame = StormScene.frame(time: ctx.time, size: ctx.size, intensity: ctx.intensity, touches: ctx.touches, sample: ctx.sample)
        try gpu.render(frame: frame, source: source, target: target)
    }
}

nonisolated final class OrigamiFX: FXEffect {
    let gpu: OrigamiGPU
    init(kit: FXKit) throws { gpu = try OrigamiGPU(libraryURL: try fxLabLibrary("origami")) }
    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let frame = OrigamiScene.frame(time: ctx.time, size: ctx.size, intensity: ctx.intensity, touches: ctx.touches, sample: ctx.sample)
        try gpu.render(frame: frame, source: source, target: target)
    }
}
