import UIKit
import XCTest
@testable import kicklab

@MainActor
final class CounterLabelTests: XCTestCase {
    func testOldReplaySettingsStillDecodeAndCustomTextRoundTrips() throws {
        let old = Data(#"{"counter":{"enabled":true,"style":"normal","placement":{"x":0.3,"y":0.6,"scale":1.2}}}"#.utf8)
        var settings = try JSONDecoder().decode(ExportOverlaySettings.self, from: old)
        XCTAssertNil(settings.counter.customLabel)
        settings.counter.customLabel = "Ballkontakte"
        XCTAssertEqual(try JSONDecoder().decode(ExportOverlaySettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.counter.customLabel = nil
        XCTAssertEqual(CounterLabel.display(settings.counter.customLabel), "Touches")
    }

    func testEmptyPastedAndMultilingualTextAreBoundedWithoutChangingScoring() {
        XCTAssertNil(CounterLabel.saved("Touches"))
        XCTAssertNil(CounterLabel.saved(" \n\t"))
        XCTAssertNil(CounterLabel.saved("  Touches  "))
        XCTAssertEqual(CounterLabel.saved("  Meine\nBallkontakte  "), "Meine Ballkontakte")
        XCTAssertEqual(CounterLabel.display(" \n\t"), "Touches")
        XCTAssertEqual(CounterLabel.display("  Meine\nBallkontakte \t"), "Meine Ballkontakte")
        XCTAssertEqual(CounterLabel.editable("Ö" + String(repeating: "ä", count: 30)), "Ö" + String(repeating: "ä", count: 23))
        XCTAssertEqual(CounterLabel.editable("Ball "), "Ball ", "A space must survive while the user types a second word")
        let state = ExportCounterState(count: 37, isTotal: false, age: 0.2)
        let custom = state.withLabel("Ballkontakte")
        XCTAssertEqual(custom.label, "BALLKONTAKTE")
        XCTAssertEqual(custom.count, state.count)
        XCTAssertEqual(custom.age, state.age)
        XCTAssertEqual(custom.isTotal, state.isTotal)
        XCTAssertEqual(ExportCounterState(count: 37, isTotal: true, age: nil).withLabel("Toques").label, "TOTAL TOQUES")
    }

    func testAllTwelveStylesApplyLabelToPreviewAndExportAndResetExactly() throws {
        let samples = ["Touches", "Ballkontakte", "Ö" + String(repeating: "W", count: 23)]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 2160), format: format).image { canvas in
            UIColor(white: 0.06, alpha: 1).setFill(); canvas.fill(CGRect(x: 0, y: 0, width: 720, height: 2160))
            for (row, style) in ExportBadgeStyle.allCases.enumerated() {
                for (column, label) in samples.enumerated() {
                    let age = CounterArt.previewAge(style)
                    if let badge = ExportOverlayRenderer.image(style: style, time: 24 + age,
                        counter: .init(count: 24, isTotal: false, age: age), scale: 1, customLabel: label) {
                        UIImage(cgImage: badge).draw(at: CGPoint(x: column * 240, y: row * 180))
                    }
                }
            }
        }
        let attachment = XCTAttachment(image: sheet)
        attachment.name = "All 12 counters — default, German, maximum length"
        attachment.lifetime = .keepAlways; add(attachment)

        for style in ExportBadgeStyle.allCases {
            let state = ExportCounterState(count: 24, isTotal: false, age: CounterArt.previewAge(style))
            func preview(_ text: String?) throws -> Data {
                let image = try XCTUnwrap(ExportOverlayRenderer.image(style: style, time: 24.6, counter: state, scale: 1, customLabel: text))
                return try XCTUnwrap(image.dataProvider?.data) as Data
            }
            func export(_ text: String?) throws -> Data {
                var settings = ExportOverlaySettings()
                settings.counter.style = style; settings.counter.customLabel = text
                settings.timer.enabled = false; settings.milestones = false
                let ctx = try XCTUnwrap(CGContext(data: nil, width: 480, height: 640, bitsPerComponent: 8, bytesPerRow: 1920,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ExportOverlayRenderer.draw(in: ctx, size: CGSize(width: 480, height: 640), settings: settings, time: 24.6, counter: state)
                return try XCTUnwrap(ctx.makeImage()?.dataProvider?.data) as Data
            }
            XCTAssertNotEqual(try preview(nil), try preview("Ballkontakte"), "\(style) preview must use the new text")
            XCTAssertNotEqual(try export(nil), try export("Ballkontakte"), "\(style) exported frames must use the new text")
            XCTAssertEqual(try preview(nil), try preview("Touches"), "\(style) default/reset is unchanged")
            XCTAssertEqual(try preview(nil), try preview(" \n"), "\(style) blank text falls back to Touches")
        }
    }
}
