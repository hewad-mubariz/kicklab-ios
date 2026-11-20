import SwiftUI
import XCTest
@testable import kicklab

/// The Analytics grid's tiles side by side, saved to TILES_OUT (TEST_RUNNER_TILES_OUT) for design review.
@MainActor
final class AnalyticsTilesSnapshotTests: XCTestCase {
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
