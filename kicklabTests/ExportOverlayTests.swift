import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import kicklab

struct ExportOverlayTests {
    @Test func normalIsTheDefaultAndOldCounterChoicesRemainAvailable() throws {
        #expect(ExportOverlaySettings().counter.style == .normal)
        #expect(ExportBadgeStyle.allCases.count == 12)
        #expect(ExportBadgeStyle.allCases.contains(.classic))
        #expect(ExportBadgeStyle.allCases.contains(.odometer))
        #expect(NormalCounterAppearance.label(5) == "05")
        #expect(NormalCounterAppearance.label(124) == "124")
        let font = CTFontCreateWithName(NormalCounterAppearance.fontName as CFString, 84, nil)
        #expect(CTFontCopyPostScriptName(font) as String == NormalCounterAppearance.fontName)
        var choice = ExportOverlaySettings()
        choice.counter.style = .goldCoin
        let restored = try JSONDecoder().decode(ExportOverlaySettings.self, from: JSONEncoder().encode(choice))
        #expect(restored.counter.style == .goldCoin)
        choice.counter.style = .classic
        let classic = try JSONDecoder().decode(ExportOverlaySettings.self, from: JSONEncoder().encode(choice))
        #expect(classic.counter.style == .classic)
    }

    @Test func retiredCounterStylesFallBackToNormalAndKeepTheirLayout() throws {
        let old = Data(#"{"counter":{"enabled":true,"style":"particleBurst","placement":{"x":0.3,"y":0.6,"scale":1.2,"rotation":10}}}"#.utf8)
        let restored = try JSONDecoder().decode(ExportOverlaySettings.self, from: old)
        #expect(restored.counter.style == .normal)
        #expect(restored.counter.placement == .init(x: 0.3, y: 0.6, scale: 1.2, rotation: 10))
    }

    @Test func showpieceCountersReactToATouchAndSettleWhenIdle() throws {
        for style in ExportBadgeStyle.allCases where style != .normal && style != .classic {
            func pixels(age: Double?, time: Double) throws -> Data {
                let image = try #require(ExportOverlayRenderer.image(style: style, time: time,
                    counter: .init(count: 24, isTotal: false, age: age), scale: 1))
                return try #require(image.dataProvider?.data) as Data
            }
            #expect(try pixels(age: 0.1, time: 30.1) != pixels(age: 30, time: 60), "\(style) shows the touch")
            #expect(try pixels(age: nil, time: 12) == pixels(age: -1, time: 12), "\(style) treats a missing touch as idle")
        }
    }

    @Test func classicBurstOnlyAppearsForARecentRecordedTouch() throws {
        func pixels(age: Double?, total: Bool = false) throws -> Data {
            let image = try #require(ExportOverlayRenderer.image(style: .classic, time: 10,
                counter: .init(count: 5, isTotal: total, age: age), scale: 1))
            return try #require(image.dataProvider?.data) as Data
        }
        let settled = try pixels(age: nil)
        #expect(try pixels(age: 0.15) != settled)
        #expect(try pixels(age: 2) == settled)
        #expect(try pixels(age: -1) == settled)
        #expect(try pixels(age: .nan) == settled)
        #expect(try pixels(age: 0.15, total: true) == pixels(age: nil, total: true))
    }

    @Test func placementKeepsRotatedCornersInsideEveryOrientationAndQuality() {
        for size in [CGSize(width: 720, height: 1280), .init(width: 1080, height: 1920), .init(width: 1920, height: 1080), .init(width: 1080, height: 1080)] {
            for x in [-1.0, 0, 0.3, 1, 2] { for y in [0.0, 0.5, 1] { for scale in [0.5, 1.0, 1.75, 5] {
                for angle in [0.0, 15, 45, 90, 135, 180, 270, 360] {
                    let placement = ExportOverlayPlacement(x: x, y: y, scale: scale, rotation: angle)
                    let bounds = placement.rotatedBounds(in: size)
                    let margin = min(size.width, size.height) * 0.025
                    #expect(bounds.minX >= margin - 0.001 && bounds.maxX <= size.width - margin + 0.001)
                    #expect(bounds.minY >= margin - 0.001 && bounds.maxY <= size.height - margin + 0.001)
                }
            } } }
        }
        let placement = ExportOverlayPlacement(x: 0.72, y: 0.81, scale: 1.3, rotation: 38)
        let small = placement.rect(in: .init(width: 720, height: 1280))
        let large = placement.rect(in: .init(width: 1080, height: 1920))
        #expect(abs(small.midX * 1.5 - large.midX) < 0.001)
        #expect(abs(small.midY * 1.5 - large.midY) < 0.001)
        #expect(abs(small.width * 1.5 - large.width) < 0.001)
    }

    @Test func draggingUsesVideoSpaceAfterRotationAndClampsAtTheEdges() {
        let size = CGSize(width: 360, height: 640), original = ExportOverlayPlacement(x: 0.3, y: 0.5, rotation: 37)
        let before = original.rect(in: size)
        let moved = original.translated(by: .init(width: 15, height: -27), in: size)
        let after = moved.rect(in: size)
        #expect(abs(after.midX - before.midX - 15) < 0.001)
        #expect(abs(after.midY - before.midY + 27) < 0.001)
        let edge = original.translated(by: .init(width: 4000, height: -4000), in: size)
        #expect(edge.x == 1 && edge.y == 0)
        let invalid = ExportOverlayPlacement(x: .nan, y: .infinity, scale: .nan, rotation: .nan).rotatedBounds(in: size)
        #expect(CGRect(origin: .zero, size: size).contains(invalid))
    }

    @Test func PinchingAndTwistingPreserveCenterAndComposeWithMovement() {
        let size = CGSize(width: 720, height: 1280)
        let start = ExportOverlayPlacement(x: 0.4, y: 0.6, scale: 0.8)
        let before = start.rect(in: size)
        var changed = start.transformed(scale: 1.1, rotation: 37, in: size)
        let after = changed.rect(in: size)
        #expect(abs(before.midX - after.midX) < 0.001)
        #expect(abs(before.midY - after.midY) < 0.001)
        changed = changed.translated(by: .init(width: 12, height: -8), in: size)
        changed = changed.transformed(scale: 0.9, rotation: 397, in: size)
        #expect(changed.rotation == 37)
        let moved = changed.rect(in: size)
        #expect(abs(moved.midX - before.midX - 12) < 0.001)
        #expect(abs(moved.midY - before.midY + 8) < 0.001)
        #expect(changed.contains(CGPoint(x: moved.midX, y: moved.midY), in: size))
        let bounds = changed.rotatedBounds(in: size)
        #expect(!changed.contains(CGPoint(x: bounds.maxX, y: bounds.maxY), in: size))
    }

    @Test func migrationRemovesTheTimerAndKeepsExistingCounterLayout() throws {
        let old = Data(#"{"counter":{"enabled":true,"style":"ice","placement":{"x":0.2,"y":0.7,"scale":0.85}},"timer":{"enabled":true,"style":"galaxy","placement":{"x":0.8,"y":0.4,"scale":0.6}}}"#.utf8)
        let migrated = try JSONDecoder().decode(ExportOverlaySettings.self, from: old)
        // Ice was retired with the old counter set: it falls back to Normal, keeping the layout.
        #expect(migrated.counter.style == .normal)
        #expect(migrated.counter.placement == .init(x: 0.2, y: 0.7, scale: 0.85, rotation: 0))
        let saved = try JSONEncoder().encode(migrated)
        #expect(!String(decoding: saved, as: UTF8.self).contains("timer"))
        var rotated = migrated; rotated.counter.placement.rotation = -25
        #expect(rotated != migrated)
        #expect(try JSONDecoder().decode(ExportOverlaySettings.self, from: JSONEncoder().encode(rotated)) == rotated)
    }

    @Test func everyCounterStyleIsDistinctAndReproducibleAfterSeeking() throws {
        var images = Set<Data>()
        for style in ExportBadgeStyle.allCases {
            let state = ExportCounterState(count: 24, isTotal: false, age: 0.15)
            let first = try #require(ExportOverlayRenderer.image(style: style, time: 24.15, counter: state, scale: 1))
            _ = ExportOverlayRenderer.image(style: style, time: 81, counter: .init(count: 51, isTotal: false, age: 0))
            let repeated = try #require(ExportOverlayRenderer.image(style: style, time: 24.15, counter: state, scale: 1))
            let bytes = first.dataProvider!.data! as Data
            #expect(bytes == repeated.dataProvider!.data! as Data)
            #expect(bytes.contains { $0 > 200 })
            images.insert(bytes)
        }
        #expect(images.count == ExportBadgeStyle.allCases.count)
    }

    @Test func exportRotationIsClockwiseAroundTheStickerCenterAndOffDrawsNothing() throws {
        let side = 256, size = CGSize(width: 256, height: 256)
        func render(_ settings: ExportOverlaySettings) throws -> Data {
            let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            ExportOverlayRenderer.draw(in: ctx, size: size, settings: settings, time: 5,
                counter: .init(count: 24, isTotal: false, age: 2))
            return ctx.makeImage()!.dataProvider!.data! as Data
        }
        func centroid(_ pixels: Data) -> CGPoint {
            var weight = 0.0, xSum = 0.0, ySum = 0.0
            for y in 0..<side { for x in 0..<side {
                let alpha = Double(pixels[(y * side + x) * 4 + 3])
                weight += alpha; xSum += (Double(x) + 0.5) * alpha; ySum += (Double(y) + 0.5) * alpha
            } }
            return CGPoint(x: xSum / weight, y: ySum / weight)
        }
        var settings = ExportOverlaySettings()
        settings.counter.style = .odometer
        settings.counter.placement = .init(x: 0.5, y: 0.5)
        let upright = centroid(try render(settings))
        settings.counter.placement.rotation = 90
        let rotated = centroid(try render(settings))
        #expect(abs(rotated.x - (size.width - upright.y)) < 0.5)
        #expect(abs(rotated.y - upright.x) < 0.5)
        settings.counter.enabled = false
        let blank = try render(settings)
        #expect(blank.allSatisfy { $0 == 0 })
    }
}
