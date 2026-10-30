import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import kicklab

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

    @Test func celebrationDrawsTheSameFrameTwiceAndEndsClean() throws {
        let first = try #require(MilestoneAppearance.image(count: 50, progress: 0.3, scale: 1))
        let again = try #require(MilestoneAppearance.image(count: 50, progress: 0.3, scale: 1))
        #expect(first.dataProvider!.data! as Data == again.dataProvider!.data! as Data)
        #expect(coverage(first) > 2_000, "The burst, confetti and tag are visible")
        #expect(coverage(MilestoneAppearance.image(count: 50, progress: 1, scale: 1)) == 0)
        let other = try #require(MilestoneAppearance.image(count: 75, progress: 0.3, scale: 1))
        #expect(other.dataProvider!.data! as Data != first.dataProvider!.data! as Data, "Each milestone's confetti and tag differ")
    }

    @Test func exportDrawsTheCelebrationAroundTheCounter() throws {
        let side = 400, size = CGSize(width: 400, height: 400)
        func render(_ settings: ExportOverlaySettings, _ state: ExportCounterState) throws -> Int {
            let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            ExportOverlayRenderer.draw(in: ctx, size: size, settings: settings, time: 12, counter: state)
            return coverage(ctx.makeImage())
        }
        var settings = ExportOverlaySettings()
        settings.timer.enabled = false
        settings.counter.placement = .init(x: 0.5, y: 0.5, scale: 1)
        let celebrating = try render(settings, .init(count: 10, isTotal: false, age: 0.3))
        let ordinary = try render(settings, .init(count: 11, isTotal: false, age: 0.3))
        settings.milestones = false
        let off = try render(settings, .init(count: 10, isTotal: false, age: 0.3))
        #expect(celebrating > off + 3_000, "\(celebrating) vs \(off)")
        #expect(try render(settings, .init(count: 11, isTotal: false, age: 0.3)) == ordinary,
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
        let soundtrack = ReplaySoundtrack(edit: edit, touchTimes: touches, milestones: true)
        #expect(soundtrack.events.count == 12, "One sound per touch")
        #expect(soundtrack.events[9].sound == .milestone && soundtrack.events[9].time == touches[9])
        #expect(!soundtrack.events.contains { $0.sound == .swap(edit.swapSound) }, "The fanfare wins over the change sound")
        let quiet = ReplaySoundtrack(edit: edit, touchTimes: touches, milestones: false)
        #expect(quiet.events[9].sound == .swap(edit.swapSound))
        let fanfare = ReplaySoundSynth.samples(.milestone)
        #expect(ReplaySoundSynth.duration(.milestone) < 0.85)
        #expect(fanfare.allSatisfy { abs($0) <= 1 } && (fanfare.map { abs($0) }.max() ?? 0) > 0.5)
    }

    /// With MILESTONE_SHOTS set, the celebration over a grey frame at several moments, for review.
    @Test func savesCelebrationFramesForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["MILESTONE_SHOTS"], !folder.isEmpty else { return }
        let size = CGSize(width: 720, height: 1280)
        var settings = ExportOverlaySettings()
        settings.timer.enabled = true
        for (index, age) in [0.05, 0.15, 0.3, 0.55, 0.9, 1.2].enumerated() {
            let ctx = try #require(CGContext(data: nil, width: 720, height: 1280, bitsPerComponent: 8, bytesPerRow: 720 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: 0.3, green: 0.42, blue: 0.27, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            ExportOverlayRenderer.draw(in: ctx, size: size, settings: settings, time: 6 + age,
                                       counter: .init(count: 25, isTotal: false, age: age))
            let url = URL(fileURLWithPath: folder).appendingPathComponent("milestone-\(index).png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
