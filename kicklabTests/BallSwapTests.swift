import CoreGraphics
import Foundation
import Testing
@testable import kicklab

struct BallSwapTests {
    private let touches: [Double] = [1, 2, 3, 4, 5]

    @Test func perTouchBallResolvesFromTheLatestChange() {
        var edit = SessionEditState(style: .none, intensity: 0)
        edit.ballChanges = [1: .lava, 3: .chrome]
        #expect(edit.ballSkin(forTouch: 0) == .original)
        #expect(edit.ballSkin(forTouch: 1) == .lava)
        #expect(edit.ballSkin(forTouch: 2) == .lava)
        #expect(edit.ballSkin(forTouch: 3) == .chrome)
        #expect(edit.ballSkin(forTouch: 40) == .chrome)
        #expect(edit.ballSkin(at: 0.5, touchTimes: touches) == .original)
        #expect(edit.ballSkin(at: 2, touchTimes: touches) == .lava)
        #expect(edit.ballSkin(at: 2.999, touchTimes: touches) == .lava)
        #expect(edit.ballSkin(at: 3, touchTimes: touches) == .lava, "Touch index 2 is the third touch")
        #expect(edit.ballSkin(at: 4, touchTimes: touches) == .chrome)
        #expect(edit.ballSkin(at: 10, touchTimes: touches) == .chrome)
        #expect(edit.ballSkin(at: .nan, touchTimes: touches) == .original)
        // A base print applies before the first change and wherever nothing overrides it.
        edit.ballSkin = .gold
        #expect(edit.ballSkin(at: 0.5, touchTimes: touches) == .gold)
        #expect(edit.ballSkin(forTouch: 0) == .gold)
        var single = SessionEditState(style: .none, intensity: 0, ballSkin: .volt)
        single.ballChanges = [:]
        #expect(single.ballSkin(at: 3, touchTimes: touches) == .volt)
    }

    @Test func swapsListOnlyRealChanges() {
        var edit = SessionEditState(style: .none, intensity: 0)
        edit.ballChanges = [0: .original, 1: .lava, 2: .lava, 3: .chrome, 4: .original]
        let swaps = edit.ballSwaps(touchTimes: touches)
        #expect(swaps.map(\.index) == [1, 3, 4])
        #expect(swaps.map(\.time) == [2, 4, 5])
        #expect(swaps.map(\.from) == [.original, .lava, .chrome])
        #expect(swaps.map(\.to) == [.lava, .chrome, .original])
        #expect(SessionEditState(style: .none, intensity: 0, ballSkin: .gold).ballSwaps(touchTimes: touches).isEmpty)
        #expect(edit.ballsInOrder == [.original, .lava, .chrome])
    }

    @Test func timelineReportsAgeOnlyInsideTheMoment() {
        var edit = SessionEditState(style: .none, intensity: 0)
        edit.ballChanges = [1: .lava]
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

    @Test func cyclingAssignsBallsEveryNTouches() {
        var edit = SessionEditState(style: .none, intensity: 0)
        edit.cycleBalls([.volt, .lava, .chrome], every: 2, touchCount: 7)
        #expect(edit.ballChanges == [0: .volt, 2: .lava, 4: .chrome, 6: .volt])
        #expect((0..<7).map { edit.ballSkin(forTouch: $0) } == [.volt, .volt, .lava, .lava, .chrome, .chrome, .volt])
        edit.cycleBalls([.gold], every: 1, touchCount: 7)
        #expect(edit.ballChanges.isEmpty, "One ball is no cycle")
        edit.cycleBalls([.gold, .pearl], every: 0, touchCount: 3)
        #expect(edit.ballChanges == [0: .gold, 1: .pearl, 2: .gold], "A zero step still advances")
    }

    @Test func materialAndSoundFlagsFollowTheChanges() {
        var edit = SessionEditState(style: .none, intensity: 0)
        #expect(!edit.usesBallMaterial && !edit.isEdited && !edit.hasSounds)
        edit.ballChanges = [2: .original]
        #expect(!edit.usesBallMaterial, "Original on every touch needs no print")
        #expect(edit.isEdited, "A change list is still an edit")
        edit.ballChanges = [2: .galaxy]
        #expect(edit.usesBallMaterial && edit.requiresVisualTrack)
        #expect(edit.label.contains("Ball per touch"))
        edit.ballChanges = [:]
        edit.swapSound = .chime
        #expect(!edit.hasSounds, "A change sound without changes never plays")
        edit.touchSound = .pop
        #expect(edit.hasSounds && edit.isEdited)
        #expect(edit.label.contains("Pop touches"))
        let free = JugglingReplayLook(edit: edit, overlays: ExportOverlaySettings(), showGraph: false).allowed(isPro: false)
        #expect(free.edit.touchSound == .none && free.edit.ballChanges.isEmpty, "Locked choices stay off the clip")
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
