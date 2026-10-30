import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import kicklab

/// Serialized: the frame checks compare bytes, and Core Graphics very rarely rasterizes a few
/// pixels differently when many frames render at once. Timings are steadier too.
@Suite(.serialized)
struct MilestoneTests {
    @Test func milestonesFallOnTheRightTouches() {
        #expect((1...400).filter(Milestones.isMilestone) == [10, 25, 50, 75, 100, 150, 200, 250, 300, 350, 400])
        #expect(Milestones.touchIndices(touchCount: 9).isEmpty)
        #expect(Milestones.touchIndices(touchCount: 60) == [9, 24, 49], "Indices are touch numbers minus one")
    }

    @Test func celebrationRunsForItsDurationAfterTheMilestoneTouch() throws {
        #expect(Milestones.active(.init(count: 9, isTotal: false, age: 0.1)) == nil)
        #expect(Milestones.active(.init(count: 10, isTotal: true, age: 0.1)) == nil, "Totals never celebrate")
        #expect(Milestones.active(.init(count: 10, isTotal: false, age: nil)) == nil)
        let start = try #require(Milestones.active(.init(count: 25, isTotal: false, age: 0)))
        #expect(start.count == 25 && start.progress == 0)
        let middle = try #require(Milestones.active(.init(count: 25, isTotal: false, age: Milestones.duration / 2)))
        #expect(abs(middle.progress - 0.5) < 0.0001)
        #expect(Milestones.active(.init(count: 25, isTotal: false, age: Milestones.duration)) == nil)
        // The counter swells, then settles back to its size.
        #expect(Milestones.pulse(0) == 1)
        #expect(Milestones.pulse(0.12 / Milestones.duration) > 1.2)
        #expect(abs(Milestones.pulse(0.999) - 1) < 0.01)
    }

    private func coverage(_ image: CGImage?) -> Int {
        guard let image, let data = image.dataProvider?.data as Data? else { return 0 }
        return stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + (data[$1] > 8 ? 1 : 0) }
    }

    /// Total opacity, so faint pixels count for little.
    private func ink(_ image: CGImage?) -> Int {
        guard let image, let data = image.dataProvider?.data as Data? else { return 0 }
        return stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + Int(data[$1]) }
    }

    @Test func celebrationDrawsTheSameFrameTwiceAndEndsClean() throws {
        let first = try #require(MilestoneAppearance.image(count: 50, progress: 0.3, scale: 1))
        let again = try #require(MilestoneAppearance.image(count: 50, progress: 0.3, scale: 1))
        #expect(first.dataProvider!.data! as Data == again.dataProvider!.data! as Data)
        #expect(coverage(first) > 2_000, "The burst, confetti and tag are visible")
        #expect(coverage(MilestoneAppearance.image(count: 50, progress: 1, scale: 1)) == 0)
        let other = try #require(MilestoneAppearance.image(count: 75, progress: 0.3, scale: 1))
        #expect(other.dataProvider!.data! as Data != first.dataProvider!.data! as Data, "Each milestone's confetti and tag differ")
    }

    @Test(arguments: ExportBadgeStyle.allCases)
    func everyCounterHasItsOwnCelebrationThatFadesOut(_ style: ExportBadgeStyle) throws {
        let image = try #require(MilestoneAppearance.image(style: style, count: 25, progress: 0.3, scale: 1))
        let again = try #require(MilestoneAppearance.image(style: style, count: 25, progress: 0.3, scale: 1))
        #expect(image.dataProvider!.data! as Data == again.dataProvider!.data! as Data, "Deterministic")
        let shown = coverage(image)
        #expect(shown > 2_000, "\(style) celebrates: \(shown) pixels")
        if style != .normal {
            let normal = try #require(MilestoneAppearance.image(count: 25, progress: 0.3, scale: 1))
            #expect(image.dataProvider!.data! as Data != normal.dataProvider!.data! as Data, "\(style) is not the Normal burst")
        }
        // Gone by the end, without popping off: the last frames are nearly transparent.
        let peak = [0.2, 0.4, 0.6].map { ink(MilestoneAppearance.image(style: style, count: 25, progress: $0, scale: 1)) }.max()!
        let last = ink(MilestoneAppearance.image(style: style, count: 25, progress: 0.99, scale: 1))
        #expect(last < peak / 12, "\(style) still shows \(last) of \(peak) at the end")
        #expect(coverage(MilestoneAppearance.image(style: style, count: 25, progress: 1, scale: 1)) == 0)
        // Some draw over the counter too; the rest have no front layer at all.
        let fronts = [0.1, 0.25, 0.45].map { MilestoneAppearance.image(style: style, count: 25, progress: $0, front: true, scale: 1) }
        #expect(fronts.allSatisfy { ($0 != nil) == MilestoneAppearance.hasFront(style) })
        if MilestoneAppearance.hasFront(style) {
            #expect(fronts.map(coverage).max()! > 100, "\(style) front layer draws")
        }
        // The badge moves its own way and always comes to rest.
        let rest = Milestones.motion(style, progress: 0.999)
        #expect(abs(rest.scaleX - 1) < 0.02 && abs(rest.scaleY - 1) < 0.02 && abs(rest.angle) < 0.01
                && abs(rest.dx) < 0.5 && abs(rest.dy) < 0.5, "\(style) rests at \(rest)")
    }

    @Test func countersMoveDifferently() {
        let moments = [0.02, 0.05, 0.1, 0.2, 0.35]
        let shapes = ExportBadgeStyle.allCases.map { style in moments.map { Milestones.motion(style, progress: $0) } }
        #expect(Set(shapes.map { "\($0)" }).count >= 9, "Most counters have their own motion")
        #expect(Milestones.motion(.comic, progress: 0).scaleX > 1.3, "Comic slams in")
        #expect(Milestones.motion(.jelly, progress: 0.1).scaleX != Milestones.motion(.jelly, progress: 0.1).scaleY, "Jelly squashes")
        #expect(Milestones.motion(.goldCoin, progress: 0.15).dy < -10, "The medal hops")
        var normal = MilestoneMotion()
        normal.scale(Milestones.pulse(0.1))
        #expect(Milestones.motion(.normal, progress: 0.1) == normal, "Normal keeps its swell")
    }

    @Test func wordsAndLevelsGrowWithTheStreak() {
        #expect(Milestones.cheer(10) == "NICE!" && Milestones.cheer(100) == "LEGEND!")
        #expect(Set([150, 200, 250, 300].map(Milestones.cheer)).count == 4)
        #expect(Milestones.level(10) == 2 && Milestones.level(25) == 3 && Milestones.level(100) == 6 && Milestones.level(150) == 7)
    }

    @Test(arguments: [ExportBadgeStyle.normal, .comic, .chalk, .goldCoin])
    func exportDrawsTheCelebrationAroundTheCounter(_ style: ExportBadgeStyle) throws {
        let side = 400, size = CGSize(width: 400, height: 400)
        func render(_ settings: ExportOverlaySettings, _ state: ExportCounterState) throws -> Data {
            let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            ExportOverlayRenderer.draw(in: ctx, size: size, settings: settings, time: 12, counter: state)
            return try #require(ctx.makeImage()?.dataProvider?.data as Data?)
        }
        func changed(_ a: Data, _ b: Data) -> Int {
            stride(from: 0, to: min(a.count, b.count), by: 4).reduce(0) { count, i in
                count + ((0..<4).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > 8 } ? 1 : 0)
            }
        }
        var settings = ExportOverlaySettings()
        settings.timer.enabled = false
        settings.counter.style = style
        settings.counter.placement = .init(x: 0.5, y: 0.5, scale: 1)
        let celebrating = try render(settings, .init(count: 10, isTotal: false, age: 0.5))
        let ordinary = try render(settings, .init(count: 11, isTotal: false, age: 0.5))
        settings.milestones = false
        let off = try render(settings, .init(count: 10, isTotal: false, age: 0.5))
        #expect(changed(celebrating, off) > 3_000, "\(style): \(changed(celebrating, off)) pixels change")
        #expect(try render(settings, .init(count: 11, isTotal: false, age: 0.5)) == ordinary,
                "An ordinary touch draws the same counter either way")
    }

    @Test func settingsDefaultOnAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(ExportOverlaySettings.self, from: Data("{}".utf8))
        #expect(legacy.milestones && legacy.milestoneSound && legacy.playsMilestoneSound)
        var settings = ExportOverlaySettings()
        settings.milestones = false
        settings.milestoneSound = false
        #expect(try JSONDecoder().decode(ExportOverlaySettings.self, from: JSONEncoder().encode(settings)) == settings)
        settings.milestones = true
        #expect(!settings.playsMilestoneSound, "No fanfare when it is switched off")
        settings.milestoneSound = true; settings.counter.enabled = false
        #expect(!settings.playsMilestoneSound, "No fanfare without the counter")
    }

    @Test func fanfareReplacesTheTouchAndChangeSoundsOnAMilestone() {
        let touches = (0..<12).map { Double($0) * 0.5 + 0.5 }
        var edit = SessionEditState(style: .none, intensity: 0.8)
        edit.touchSound = .pop
        edit.lookChanges = [9: TouchLook(ball: .lava, effect: .fire)]
        let soundtrack = ReplaySoundtrack(edit: edit, touchTimes: touches, milestones: .goldCoin)
        #expect(soundtrack.events.count == 12, "One sound per touch")
        #expect(soundtrack.events[9].sound == .milestone(.goldCoin) && soundtrack.events[9].time == touches[9],
                "The counter's own fanfare")
        #expect(!soundtrack.events.contains { $0.sound == .swap(edit.swapSound) }, "The fanfare wins over the change sound")
        let quiet = ReplaySoundtrack(edit: edit, touchTimes: touches)
        #expect(quiet.events[9].sound == .swap(edit.swapSound))
        var settings = ExportOverlaySettings()
        settings.counter.style = .neon
        #expect(settings.milestoneFanfare == .neon)
        settings.milestoneSound = false
        #expect(settings.milestoneFanfare == nil)
    }

    @Test func everyCounterHasItsOwnFanfare() {
        var fingerprints: Set<[Float]> = []
        for style in ExportBadgeStyle.allCases {
            let fanfare = ReplaySoundSynth.samples(.milestone(style))
            #expect(ReplaySoundSynth.duration(.milestone(style)) < 1, "\(style) stays short")
            #expect(fanfare.allSatisfy { abs($0) <= 1 } && (fanfare.map { abs($0) }.max() ?? 0) > 0.5, "\(style) is audible and unclipped")
            #expect(fanfare == ReplaySoundSynth.samples(.milestone(style)), "\(style) is the same every time")
            fingerprints.insert(stride(from: 0, to: min(fanfare.count, 20_000), by: 997).map { fanfare[$0] })
        }
        #expect(fingerprints.count == ExportBadgeStyle.allCases.count - 1, "Only Classic shares Normal's fanfare")
    }

    /// With MILESTONE_SHOTS set, every counter style through its celebration over a grey frame, for review.
    @Test func savesCelebrationFramesForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["MILESTONE_SHOTS"], !folder.isEmpty else { return }
        let size = CGSize(width: 720, height: 540)
        var settings = ExportOverlaySettings()
        settings.timer.enabled = false
        settings.counter.placement = .init(x: 0.5, y: 0.5, scale: 0.8)
        for style in ExportBadgeStyle.allCases {
            // What the replay pays per frame for this style's layers, at the editor's scale.
            let start = ProcessInfo.processInfo.systemUptime
            for step in 0..<20 {
                _ = MilestoneAppearance.image(style: style, count: 25, progress: Double(step) / 20)
                _ = MilestoneAppearance.image(style: style, count: 25, progress: Double(step) / 20, front: true)
            }
            print("MILESTONECOST \(style.rawValue) \((ProcessInfo.processInfo.systemUptime - start) / 20 * 1000) ms")
            settings.counter.style = style
            for (index, age) in [0.06, 0.18, 0.35, 0.6, 0.95, 1.25, 2.0].enumerated() {
                let ctx = try #require(CGContext(data: nil, width: 720, height: 540, bitsPerComponent: 8, bytesPerRow: 720 * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(CGColor(red: 0.3, green: 0.42, blue: 0.27, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
                ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
                ExportOverlayRenderer.draw(in: ctx, size: size, settings: settings, time: 6 + age,
                                           counter: .init(count: 25, isTotal: false, age: age))
                let url = URL(fileURLWithPath: folder).appendingPathComponent("\(style.rawValue)-\(index).png")
                let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }
}
