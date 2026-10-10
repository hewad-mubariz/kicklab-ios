import CoreGraphics
import XCTest
@testable import kicklab

/// Witnesses are fixed photographed background/ball pixels, reviewed against the
/// source of the failing phone export. No inference or generated masks in this test.
final class DistantBallCoverageTests: XCTestCase {
    func testSavedPhoneBackgroundDoesNotBecomeBallBlur() throws {
        try checkWitnesses(expected: "background")
    }

    func testSavedSmallBallRimRemainsCovered() throws {
        try checkWitnesses(expected: "ball")
    }

    private func checkWitnesses(expected: String) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "distant-render-witnesses", withExtension: "json"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var checked = 0
        for row in rows where row["expected"] as? String == expected {
            let m = try XCTUnwrap(row["mask"] as? [String: Any])
            let rect = try XCTUnwrap(m["rect"] as? [Double])
            let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(m["alpha"] as? String)))
            let mask = BallMask(rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
                width: try XCTUnwrap(m["width"] as? Int), height: try XCTUnwrap(m["height"] as? Int), alpha: Array(raw))
            let f = try XCTUnwrap(row["fit"] as? [String: Any])
            let center = try XCTUnwrap(f["center"] as? [Double])
            let sourceSize = try XCTUnwrap(row["size"] as? [Double])
            let point = try XCTUnwrap(row["witness"] as? [Double])
            let smear = try XCTUnwrap(row["smear"] as? [Double])
            for scale in [0.5, 1.0, 1.5, 3.0] {
                let size = CGSize(width: sourceSize[0]*scale, height: sourceSize[1]*scale)
                let fit = BallReplacementFootprint(sourceSize: size,
                    center: CGPoint(x: center[0]*scale, y: center[1]*scale),
                    radius: try XCTUnwrap(f["radius"] as? Double)*scale,
                    radii: try XCTUnwrap(f["radii"] as? [Double]).map { $0*scale },
                    feather: try XCTUnwrap(f["feather"] as? Double)*scale, padding: 0)
                let matte = BallReplacementCoverage(mask: mask, fitted: fit, size: size,
                    smear: CGVector(dx: smear[0]*scale, dy: smear[1]*scale))
                let alpha = matte.coverage(x: point[0]*scale, y: point[1]*scale)
                let message = "\(row["case"]!) frame \(row["index"]!), scale \(scale)"
                if expected == "background" { XCTAssertLessThan(alpha, 0.1, message) }
                else { XCTAssertGreaterThan(alpha, 0.8, message) }
                XCTAssertEqual(mask.alpha, Array(raw), "The owned AI mask remains immutable")
                checked += 1
            }
        }
        XCTAssertEqual(checked, expected == "background" ? 16 : 8)
    }
}
