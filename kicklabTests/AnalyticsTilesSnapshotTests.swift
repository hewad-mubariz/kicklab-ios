import SwiftUI
import XCTest
@testable import kicklab

/// The Analytics grid's tiles side by side, saved to TILES_OUT (TEST_RUNNER_TILES_OUT) for design review.
@MainActor
final class AnalyticsTilesSnapshotTests: XCTestCase {
    func testAllAnalyticsArtworkAtPickerWidths() throws {
        guard let out = ProcessInfo.processInfo.environment["TILES_OUT"] else { throw XCTSkip("TILES_OUT not set") }
        for view in LabViewID.allCases {
            XCTAssertNotNil(UIImage(named: "analytics-preview-" + view.rawValue), "Missing artwork for \(view.title)")
        }
        // Compact and standard phones, plus a four-column contact sheet for visual review.
        for (width, columns) in [(CGFloat(320), 2), (CGFloat(390), 2), (CGFloat(800), 4)] {
            let content = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                ForEach(LabViewID.allCases) { view in LabViewTile(view: view) }
            }
            .padding(16).frame(width: width)
            .background(Color(red: 0.035, green: 0.05, blue: 0.05))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, width, accuracy: 0.5, "Artwork must not widen a grid column")
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: out)
                .appendingPathComponent("analytics-tiles-\(Int(width)).png"))
        }
    }

    func testAnalyticsTilesSnapshot() throws {
        guard let out = ProcessInfo.processInfo.environment["TILES_OUT"] else { throw XCTSkip("TILES_OUT not set") }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
        let grid = LazyVGrid(columns: columns, spacing: 10) {
            MotionStyleOption(style: .ballMotion, selected: false, width: nil)
            MotionStyleOption(style: .comet, selected: false, width: nil)
            LabViewTile(view: .footRally)
            LabViewTile(view: .ballFlight, selected: true)
            LabViewTile(view: .peakZone, selected: true, progress: 0.34)
            LabViewTile(view: .touchLens)
            LabViewTile(view: .ghostBall)
            LabViewTile(view: .legSwing)
        }
        .padding(16)
        .frame(width: 390)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: grid)
        renderer.scale = 3
        guard let image = renderer.uiImage, let png = image.pngData() else { return XCTFail("no image") }
        try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("analytics-tiles.png"))
    }
}
