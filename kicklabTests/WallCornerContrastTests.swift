#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallCornerContrastTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Sample: Decodable {
            let id: String
            let expectedPixels: [[Double]]?
            let differences: [String]
        }
        let cases: [Sample]
    }

    private func samples() throws -> [Fixture.Sample] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "wall-corner-recorded-blinks", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
    }

    private func frames(_ sample: Fixture.Sample, erase: [Double]? = nil) throws -> [WallCornerFinder.Frame] {
        let w = WallCornerFinder.width, h = WallCornerFinder.height
        let dark = [UInt8](repeating: 128, count: w * h)
        var result: [WallCornerFinder.Frame] = []
        for (pass, encoded) in sample.differences.enumerated() {
            var lit = [UInt8](try XCTUnwrap(Data(base64Encoded: encoded)))
            XCTAssertEqual(lit.count, w * h)
            if let erase {
                for y in max(0, Int(erase[1]) - 10)...min(h - 1, Int(erase[1]) + 10) {
                    for x in max(0, Int(erase[0]) - 10)...min(w - 1, Int(erase[0]) + 10) { lit[y * w + x] = 128 }
                }
            }
            for i in 0..<6 {
                result.append(WallCornerFinder.Frame(t: Double(pass * 6 + i), luma: i < 3 ? dark : lit))
            }
        }
        return result
    }

    func testRecordedDimMarkersPassAndCroppedBoardsDoNot() throws {
        for sample in try samples() {
            let found = WallCornerFinder.corners(in: try frames(sample), on: [3...5, 9...11], off: [0...2, 6...8])
            if let expected = sample.expectedPixels {
                let corners = try XCTUnwrap(found, sample.id)
                for (point, target) in zip(corners, expected) {
                    XCTAssertLessThan(hypot(point.x * 320 - target[0], point.y * 180 - target[1]), 2, sample.id)
                }
            } else {
                XCTAssertNil(found, sample.id)
            }
        }
    }

    func testRemovingAnyRealMarkerCannotBeReplacedByRoomNoise() throws {
        for sample in try samples() {
            guard let points = sample.expectedPixels else { continue }
            for point in points {
                XCTAssertNil(WallCornerFinder.corners(in: try frames(sample, erase: point),
                    on: [3...5, 9...11], off: [0...2, 6...8]), sample.id)
            }
        }
    }

    func testContrastFloorRespondsToSceneNoiseAndRejectsInvalidInputs() {
        XCTAssertEqual(WallBlinkContrast.threshold(lit: [100, 101, 99, 100], dark: [100, 100, 100, 100]), 6)
        XCTAssertEqual(WallBlinkContrast.threshold(lit: [110, 90, 110, 90], dark: [100, 100, 100, 100]), 30)
        XCTAssertEqual(WallBlinkContrast.threshold(lit: [], dark: []), .infinity)
        XCTAssertEqual(WallBlinkContrast.threshold(lit: [1], dark: []), .infinity)
    }
}
#endif
