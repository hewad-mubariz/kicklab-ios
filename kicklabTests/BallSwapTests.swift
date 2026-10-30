import CoreGraphics
import Foundation
import Testing
@testable import kicklab

/// Serialized: the frame checks compare bytes, and Core Graphics very rarely rasterizes a few
/// pixels differently when many frames render at once.
@Suite(.serialized)
struct BallSwapTests {
    private let touches: [Double] = [1, 2, 3, 4, 5]

    private func look(_ ball: BallSkin, _ effect: BallStyle = .none) -> TouchLook { TouchLook(ball: ball, effect: effect) }

    @Test func runsResolveTheLookFromTheLatestRunStart() {
        var edit = SessionEditState(style: .glowTrail, intensity: 0.8)
        edit.lookChanges = [1: look(.lava, .fire), 3: look(.chrome, .neon)]
        #expect(edit.look(forTouch: 0) == look(.original, .glowTrail), "The first run is the clip's own look")
        #expect(edit.look(forTouch: 1) == look(.lava, .fire))
        #expect(edit.look(forTouch: 2) == look(.lava, .fire))
        #expect(edit.look(forTouch: 3) == look(.chrome, .neon))
        #expect(edit.look(forTouch: 40) == look(.chrome, .neon))
        #expect(edit.ballSkin(at: 0.5, touchTimes: touches) == .original)
        #expect(edit.effect(at: 2, touchTimes: touches) == .fire)
        #expect(edit.effect(at: 2.999, touchTimes: touches) == .fire)
        #expect(edit.ballSkin(at: 3, touchTimes: touches) == .lava, "Touch index 2 is the third touch")
        #expect(edit.effect(at: 4, touchTimes: touches) == .neon)
        #expect(edit.ballSkin(at: .nan, touchTimes: touches) == .original)
        #expect(edit.runStarts == [0, 1, 3])
        #expect(edit.run(containing: 0, touchCount: 5) == 0..<1)
        #expect(edit.run(containing: 2, touchCount: 5) == 1..<3)
        #expect(edit.run(containing: 4, touchCount: 5) == 3..<5)
        // Setting the first run changes the clip's own ball and effect.
        edit.setLook(look(.gold, .galaxy), forRunStartingAt: 0)
        #expect(edit.ballSkin == .gold && edit.style == .galaxy && edit.lookChanges.count == 2)
        edit.setLook(look(.volt, .electric), forRunStartingAt: 3)
        #expect(edit.look(forTouch: 4) == look(.volt, .electric))
    }

    @Test func changesListOnlyRealLookChanges() {
        var edit = SessionEditState(style: .none, intensity: 0.8)
        // A split that keeps the same look is a run boundary but no visible change.
        edit.lookChanges = [1: look(.lava), 2: look(.lava), 3: look(.lava, .fire), 4: look(.original)]
        let swaps = edit.lookSwaps(touchTimes: touches)
        #expect(swaps.map(\.index) == [1, 3, 4])
        #expect(swaps.map(\.time) == [2, 4, 5])
        #expect(swaps.map(\.from) == [.original, .lava, .lava])
        #expect(swaps.map(\.to) == [.lava, .lava, .original])
        #expect(swaps.map(\.toEffect) == [.none, .fire, .none], "An effect-only change is still a change")
        #expect(SessionEditState(style: .fire, intensity: 1, ballSkin: .gold).lookSwaps(touchTimes: touches).isEmpty)
        // Run starts past the clip's touches are ignored.
        edit.lookChanges[9] = look(.gold)
        #expect(edit.lookSwaps(touchTimes: touches).count == 3)
    }

    @Test func effectsFadeAcrossAChangeAndDrawOnlyTheNewPath() {
        var edit = SessionEditState(style: .fire, intensity: 1)
        edit.lookChanges = [2: look(.original, .ice), 4: look(.gold, .ice)]
        // Far from changes: full strength, full trail.
        #expect(edit.effectBlend(at: 1.5, touchTimes: touches) == (1, 0.84))
        // Just before the effect change the old effect fades out.
        let before = edit.effectBlend(at: 2.95, touchTimes: touches)
        #expect(abs(before.gain - 0.5) < 0.001 && before.trail == 0.84)
        // Just after, the new one fades in and draws only the path since the change.
        let after = edit.effectBlend(at: 3.1, touchTimes: touches)
        #expect(abs(after.gain - 0.5) < 0.001 && abs(after.trail - 0.1) < 0.001)
        #expect(edit.effectBlend(at: 3.5, touchTimes: touches) == (1, 0.5))
        // A ball-only change keeps the effect running untouched.
        #expect(edit.effectBlend(at: 5.05, touchTimes: touches) == (1, 0.84))
        #expect(edit.usesEffects)
        edit.intensity = 0
        #expect(!edit.usesEffects, "Zero intensity draws nothing")
    }

    @Test func timelineReportsAgeOnlyInsideTheMoment() {
        var edit = SessionEditState(style: .none, intensity: 0)
        edit.lookChanges = [1: look(.lava)]
        edit.swapEffect = .burst
        let timeline = BallSwapTimeline(edit: edit, touchTimes: touches)
        #expect(timeline.events.count == 1)
        #expect(timeline.active(at: 1.99) == nil)
        let start = timeline.active(at: 2)
        #expect(start?.event.to == .lava)
        #expect(start.map { abs($0.age) < 0.0001 } == true)
        let middle = timeline.active(at: 2 + BallSwapEffect.duration / 2)
        #expect(middle.map { abs($0.age - 0.5) < 0.0001 } == true)
        #expect(timeline.active(at: 2 + BallSwapEffect.duration) == nil)
        #expect(timeline.active(at: 7) == nil)
        edit.swapEffect = .none
        #expect(BallSwapTimeline(edit: edit, touchTimes: touches).isEmpty)
        #expect(BallSwapTimeline(edit: edit, touchTimes: touches).active(at: 2) == nil)
    }

    @Test func recipesLayRunsThatFitTheClip() {
        let base = look(.original, .glowTrail)
        // Power-up levels up on the 10th, 25th, 50th and 100th touch of a long clip.
        let long = LookRecipes.make(.powerUp, base: base, touchCount: 120)
        #expect(long.changes.keys.sorted() == [9, 24, 49, 99])
        #expect(long.changes[9] == LookRecipes.ladder[0] && long.changes[99] == LookRecipes.ladder[3])
        #expect(long.moment == .burst)
        // A short clip levels up at quarters instead.
        let short = LookRecipes.make(.powerUp, base: base, touchCount: 12)
        #expect(short.changes.count == 3 && short.changes.keys.allSatisfy { $0 > 0 && $0 < 12 })
        // Finale keeps the clip's look until the last few touches.
        let finale = LookRecipes.make(.finale, base: base, touchCount: 30)
        #expect(finale.changes == [24: LookRecipes.finale] && finale.moment == .lightning)
        // Every 5 rotates looks and comes back to the clip's own.
        let rotation = LookRecipes.make(.everyFive, base: base, touchCount: 23)
        #expect(rotation.changes.keys.sorted() == [5, 10, 15, 20])
        #expect(rotation.changes[20] == base)
        // Remix is the same for the same seed, different for another, and never repeats a look back to back.
        let first = LookRecipes.make(.remix, base: base, touchCount: 40, seed: 1)
        #expect(first == LookRecipes.make(.remix, base: base, touchCount: 40, seed: 1))
        #expect(first != LookRecipes.make(.remix, base: base, touchCount: 40, seed: 2))
        var edit = SessionEditState(style: .glowTrail, intensity: 0.8)
        edit.lookChanges = first.changes
        let looks = edit.runStarts.map { edit.look(forTouch: $0) }
        #expect(zip(looks, looks.dropFirst()).allSatisfy { $0 != $1 })
        #expect(first.changes.keys.allSatisfy { $0 > 0 && $0 < 40 })
        // Older phones get effects that stay smooth on an iPhone 11.
        let light = LookRecipes.make(.powerUp, base: base, touchCount: 120, lightweight: true)
        #expect(light.changes.keys.sorted() == long.changes.keys.sorted(), "Same milestones, lighter effects")
        let heavy: Set<BallStyle> = [.neon, .electric, .galaxy, .rainbow, .aura, .ice, .blueFlame, .flameRibbon]
        for recipe in LookRecipe.allCases {
            let looks = LookRecipes.make(recipe, base: base, touchCount: 60, seed: 3, lightweight: true).changes.values
            #expect(!looks.contains { heavy.contains($0.effect) }, "\(recipe.title) stays light")
        }
        // Nothing to lay on a clip with one touch.
        for recipe in LookRecipe.allCases {
            #expect(LookRecipes.make(recipe, base: base, touchCount: 1).changes.isEmpty)
            #expect(!LookRecipes.make(recipe, base: base, touchCount: 8).changes.isEmpty, "\(recipe.title) changes a short clip")
        }
    }

    @Test func materialAndSoundFlagsFollowTheLooks() {
        var edit = SessionEditState(style: .none, intensity: 0.8)
        #expect(!edit.usesBallMaterial && !edit.isEdited && !edit.hasSounds && !edit.usesEffects)
        edit.lookChanges = [2: look(.original)]
        #expect(!edit.usesBallMaterial, "Original on every touch needs no print")
        #expect(edit.isEdited, "Runs are still an edit")
        edit.lookChanges = [2: look(.galaxy)]
        #expect(edit.usesBallMaterial && edit.requiresVisualTrack)
        edit.lookChanges = [2: look(.original, .fire)]
        #expect(!edit.usesBallMaterial && edit.usesEffects && edit.requiresVisualTrack, "An effect in one run needs the track")
        #expect(edit.label.contains("Looks on touches"))
        #expect(edit.withoutBallPrints().lookChanges[2] == look(.original, .fire))
        edit.lookChanges = [:]
        edit.swapSound = .chime
        #expect(!edit.hasSounds, "A change sound without changes never plays")
        edit.touchSound = .pop
        #expect(edit.hasSounds && edit.isEdited)
        #expect(edit.label.contains("Pop touches"))
        edit.lookChanges = [2: look(.lava, .fire)]
        let free = JugglingReplayLook(edit: edit, overlays: ExportOverlaySettings(), showGraph: false).allowed(isPro: false)
        #expect(free.edit.touchSound == .none && free.edit.lookChanges.isEmpty, "Locked choices stay off the clip")
    }

    private func canvas() -> CGContext {
        let ctx = CGContext(data: nil, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 160 * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 160, height: 160))
        return ctx
    }

    private func differences(_ a: [UInt8], _ b: [UInt8]) -> (count: Int, largest: Int) {
        var count = 0, largest = 0
        for (x, y) in zip(a, b) where x != y { count += 1; largest = max(largest, abs(Int(x) - Int(y))) }
        return (count, largest)
    }

    private func coverage(_ ctx: CGContext) -> (pixels: Int, bytes: [UInt8]) {
        let bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 160 * 160 * 4))
        return (stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + (bytes[$1] > 0 ? 1 : 0) }, bytes)
    }

    @Test(arguments: BallSwapEffect.allCases.filter { $0 != .none })
    func everySwapEffectDrawsDeterministicallyAndFadesOut(effect: BallSwapEffect) {
        let event = BallSwapEvent(index: 3, time: 2, from: .lava, to: .chrome)
        let first = canvas(), second = canvas(), ended = canvas()
        BallSwapRenderer.draw(in: first, center: CGPoint(x: 80, y: 80), radius: 18, effect: effect, age: 0.3, event: event)
        BallSwapRenderer.draw(in: second, center: CGPoint(x: 80, y: 80), radius: 18, effect: effect, age: 0.3, event: event)
        BallSwapRenderer.draw(in: ended, center: CGPoint(x: 80, y: 80), radius: 18, effect: effect, age: 1, event: event)
        let drawn = coverage(first)
        #expect(drawn.pixels > 40, "\(effect.title) must be visible mid-moment")
        let delta = differences(drawn.bytes, coverage(second).bytes)
        #expect(delta.count == 0, "\(effect.title) must draw the same frame twice: \(delta.count) bytes differ, largest \(delta.largest)" as Comment)
        #expect(coverage(ended).pixels == 0, "\(effect.title) must be gone once the moment has passed")
        // Premultiplied output: no channel may exceed its alpha.
        for i in stride(from: 0, to: drawn.bytes.count, by: 4) {
            #expect(drawn.bytes[i] <= drawn.bytes[i + 3] && drawn.bytes[i + 1] <= drawn.bytes[i + 3] && drawn.bytes[i + 2] <= drawn.bytes[i + 3])
        }
    }

    @Test func noneDrawsNothingAndBallScaleRestsAtOne() {
        let ctx = canvas()
        BallSwapRenderer.draw(in: ctx, center: CGPoint(x: 80, y: 80), radius: 18, effect: .none, age: 0.3,
                              event: BallSwapEvent(index: 0, time: 0, from: .original, to: .gold))
        #expect(coverage(ctx).pixels == 0)
        for effect in BallSwapEffect.allCases {
            #expect(abs(effect.ballScale(age: 0) - 1) < 0.2)
            #expect(abs(effect.ballScale(age: 1) - 1) < 0.001, "\(effect.title) settles at rest")
            #expect(effect.ballScale(age: 0.5) > 0.5 && effect.ballScale(age: 0.5) < 1.6)
        }
    }
}
