import CoreGraphics
import XCTest
@testable import kicklab

final class ContactReplacementTests: XCTestCase {
    private struct Witness: Decodable {
        struct Mask: Decodable { let rect: [Double]; let width, height: Int; let alpha: Data }
        struct Fit: Decodable { let center: [Double]; let radius: Double; let radii: [Double]; let feather: Double }
        let time: Double
        let size: [Double]
        let mask: Mask
        let fit: Fit
        let smear: [Double]
        let role: String
    }

    private func witnesses() throws -> [Witness] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "contact-replacement-20261019", withExtension: "json"))
        return try JSONDecoder().decode([Witness].self, from: Data(contentsOf: url))
    }

    func testSavedSmallMotionDoesNotRestoreTheRawMasksFlatEdges() throws {
        for row in try witnesses() where row.role == "smoothContact" {
            for scale in [0.5, 1.0, 1.5, 3.0] {
                let (mask, fit, smear) = inputs(row, scale: scale)
                let matte = BallReplacementCoverage(mask: mask, fitted: fit, size: fit.sourceSize, smear: smear)
                XCTAssertTrue(matte.reconstructsBody)
                let body = matte.footprint
                var contour: [Double] = []
                for ray in 0..<192 {
                    let angle = Double(ray) * 2 * .pi / 192
                    var edge = 0.0
                    for distance in stride(from: body.radius * 0.6, through: body.radius * 1.5, by: 0.1 * scale) {
                        if matte.coverage(x: body.center.x + cos(angle) * distance,
                                          y: body.center.y + sin(angle) * distance) > 0.5 { edge = distance }
                    }
                    contour.append(edge)
                }
                for i in contour.indices {
                    // Permit one source pixel between sampled rays, including
                    // the 0.1-pixel radial scan's quantization at a swept edge.
                    XCTAssertLessThanOrEqual(abs(contour[i] - contour[(i+1) % contour.count]), 1.0 * scale + 0.000001,
                        "Saved foot contact at \(row.time)s, render scale \(scale)")
                }
                XCTAssertGreaterThan(matte.coverage(x: body.center.x, y: body.center.y), 0.99)
                XCTAssertEqual(mask.alpha, Array(row.mask.alpha))
            }
        }
    }

    func testPrintedPanelFitCannotShrinkTheObservedBall() throws {
        let row = try XCTUnwrap(try witnesses().first { $0.role == "undersizedFit" })
        let (mask, fit, smear) = inputs(row, scale: 1)
        let matte = BallReplacementCoverage(mask: mask, fitted: fit, size: fit.sourceSize, smear: smear)
        let independent = BallReplacementCoverage(mask: mask, fitted: nil, size: fit.sourceSize, smear: smear)
        XCTAssertEqual(matte.footprint.radius, independent.footprint.radius, accuracy: 0.001)
        XCTAssertEqual(matte.footprint.center, independent.footprint.center)
        XCTAssertGreaterThan(matte.footprint.radius, fit.radii.reduce(0,+) / Double(fit.radii.count) + 1)
    }

    private func inputs(_ row: Witness, scale: Double) -> (BallMask, BallReplacementFootprint, CGVector) {
        let r = row.mask.rect
        let mask = BallMask(rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
            width: row.mask.width, height: row.mask.height, alpha: Array(row.mask.alpha))
        let fit = BallReplacementFootprint(sourceSize: CGSize(width: row.size[0]*scale, height: row.size[1]*scale),
            center: CGPoint(x: row.fit.center[0]*scale, y: row.fit.center[1]*scale), radius: row.fit.radius*scale,
            radii: row.fit.radii.map { $0*scale }, feather: row.fit.feather*scale, padding: 0)
        return (mask, fit, CGVector(dx: row.smear[0]*scale, dy: row.smear[1]*scale))
    }
}
