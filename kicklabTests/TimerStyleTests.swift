import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import kicklab

struct TimerStyleTests {
    private func bytes(_ style: TimerStyle, _ time: Double, scale: CGFloat = 1) throws -> Data {
        let image = try #require(TimerOverlayAppearance.image(style: style, time: time, scale: scale))
        return image.dataProvider!.data! as Data
    }

    /// With TIMER_STYLE_SHOTS set, every style is written as a PNG for visual review.
    private func save(_ style: TimerStyle, _ time: Double, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["TIMER_STYLE_SHOTS"], !folder.isEmpty,
              let image = TimerOverlayAppearance.image(style: style, time: time, scale: 3),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: folder).appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    @Test func everyTimerStyleIsDistinctReproducibleAndVisible() throws {
        var looks = Set<Data>()
        for style in TimerStyle.allCases {
            let time = TimerOverlayAppearance.previewTime(style)
            let first = try bytes(style, time)
            _ = try bytes(style, 3725.4)
            #expect(first == (try bytes(style, time)), "\(style.title) draws the same frame after seeking")
            #expect(first.enumerated().contains { $0.offset % 4 == 3 && $0.element > 200 }, "\(style.title) is visible")
            looks.insert(first)
            for (index, sample) in [time, 5.0, 59.6, 3725.4].enumerated() {
                save(style, sample, name: "\(style.rawValue)-\(index)")
            }
        }
        #expect(looks.count == TimerStyle.allCases.count)
    }

    @Test func eachStyleMovesWithinASecondWithoutChangingTheTime() throws {
        // Same "00:12" label, different moments: the motion comes from video time alone.
        #expect(try bytes(.pill, 12.0) != bytes(.pill, 12.5), "The live dot breathes")
        #expect(try bytes(.digital, 12.2) != bytes(.digital, 12.7), "The colon blinks")
        #expect(try bytes(.flip, 12.1) != bytes(.flip, 12.6), "The changed card folds over")
        #expect(try bytes(.flip, 12.6) == bytes(.flip, 12.9), "Cards rest once the fold is done")
        #expect(try bytes(.broadcast, 12.0) != bytes(.broadcast, 12.9), "The minute line fills")
        #expect(try bytes(.stopwatch, 12.0) != bytes(.stopwatch, 12.9), "The hand sweeps")
    }

    @Test func settingsMigrateAndRoundTrip() throws {
        let legacyOff = try JSONDecoder().decode(ExportOverlaySettings.self, from: Data(#"{"showTimer":false}"#.utf8))
        #expect(!legacyOff.timer.enabled && legacyOff.timer.style == .pill)
        #expect(legacyOff.timer.placement == TimerOverlayItem.defaultPlacement)
        // The retired counter-style timer under "timer" is ignored.
        let retired = try JSONDecoder().decode(ExportOverlaySettings.self,
            from: Data(#"{"timer":{"enabled":false,"style":"galaxy"}}"#.utf8))
        #expect(retired.timer == TimerOverlayItem())
        var settings = ExportOverlaySettings()
        settings.timer = TimerOverlayItem(enabled: true, style: .flip, placement: .init(x: 0.3, y: 0.8, scale: 1.2, rotation: -15))
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"clock\"") && text.contains("\"showTimer\":true"))
        #expect(try JSONDecoder().decode(ExportOverlaySettings.self, from: data) == settings)
        let unknown = try JSONDecoder().decode(ExportOverlaySettings.self,
            from: Data(#"{"clock":{"enabled":true,"style":"retro"}}"#.utf8))
        #expect(unknown.timer.style == .pill, "An unknown look falls back to the free Pill")
        settings.showTimer = false
        #expect(!settings.timer.enabled, "The original switch still drives the sticker")
    }

    @Test func timerLooksPastPillAreProButPlacementStaysFree() {
        var overlays = ExportOverlaySettings()
        overlays.counter.enabled = false
        overlays.timer = TimerOverlayItem(enabled: true, style: .neon, placement: .init(x: 0.2, y: 0.6, scale: 1.4, rotation: 30))
        let look = JugglingReplayLook(edit: .init(style: .none), overlays: overlays, showGraph: false)
        #expect(look.requiresPro)
        let free = look.allowed(isPro: false)
        #expect(free.overlays.timer.style == .pill)
        #expect(free.overlays.timer.placement == overlays.timer.placement)
        #expect(!free.requiresPro)
        overlays.timer.enabled = false
        #expect(!JugglingReplayLook(edit: .init(style: .none), overlays: overlays, showGraph: false).requiresPro)
    }

    @Test func timerStickerKeepsItsShapeAndStartsTopRight() {
        let video = CGSize(width: 1080, height: 1920)
        let rect = TimerOverlayItem.defaultPlacement.rect(in: video, shape: .timer)
        #expect(abs(rect.height / rect.width - 0.5) < 0.001)
        #expect(rect.midX > video.width * 0.6 && rect.midY < video.height * 0.2)
        #expect(rect.width > video.width * 0.25 && rect.width < video.width * 0.4)
        let placement = TimerOverlayItem.defaultPlacement
        #expect(placement.contains(CGPoint(x: rect.midX, y: rect.midY), in: video, shape: .timer))
        #expect(!placement.contains(CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.3), in: video, shape: .timer),
                "The wide timer does not claim the counter's taller box")
        let moved = placement.translated(by: CGSize(width: -200, height: 300), in: video, shape: .timer)
        let after = moved.rect(in: video, shape: .timer)
        #expect(abs(after.midX - (rect.midX - 200)) < 0.5 && abs(after.midY - (rect.midY + 300)) < 0.5)
        let bigger = placement.transformed(scale: placement.scale * 1.5, in: video, shape: .timer).rect(in: video, shape: .timer)
        #expect(bigger.width > rect.width * 1.4)
    }

    @Test func exportDrawsTheTimerWhereItWasPlaced() throws {
        let side = 256, size = CGSize(width: 256, height: 256)
        func centroid(_ settings: ExportOverlaySettings) throws -> CGPoint {
            let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            ExportOverlayRenderer.draw(in: ctx, size: size, settings: settings, time: 12.4,
                                       counter: .init(count: 3, isTotal: false, age: 2))
            let pixels = ctx.makeImage()!.dataProvider!.data! as Data
            var weight = 0.0, xs = 0.0, ys = 0.0
            for y in 0..<side { for x in 0..<side {
                let alpha = Double(pixels[(y * side + x) * 4 + 3])
                weight += alpha; xs += (Double(x) + 0.5) * alpha; ys += (Double(y) + 0.5) * alpha
            } }
            return CGPoint(x: xs / max(1, weight), y: ys / max(1, weight))
        }
        var settings = ExportOverlaySettings()
        settings.counter.enabled = false
        settings.timer.style = .broadcast
        settings.timer.placement = .init(x: 0, y: 0, scale: 1)
        let topLeft = try centroid(settings)
        settings.timer.placement = .init(x: 1, y: 1, scale: 1)
        let bottomRight = try centroid(settings)
        #expect(topLeft.x < 128 && topLeft.y < 128 && bottomRight.x > 128 && bottomRight.y > 128)
        settings.timer.enabled = false
        settings.graph.enabled = false
        #expect(!settings.hasVisibleOverlays)
    }
}
