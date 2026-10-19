#if DEBUG
import XCTest
@testable import kicklab

/// Rasterised observations are independent of the corners supplied to the check.
/// These establish algorithm behaviour, not physical projector accuracy.
nonisolated enum WallMappingFixture {
    static let size = CGSize(width: 1280, height: 720)
    static let corners = [CGPoint(x: 0.20, y: 0.20), CGPoint(x: 0.80, y: 0.29),
                          CGPoint(x: 0.70, y: 0.80), CGPoint(x: 0.25, y: 0.75)]
    static let on: [ClosedRange<Double>] = [3...5, 9...11]
    static let off: [ClosedRange<Double>] = [0...2, 6...8]

    static func frames(corners: [CGPoint] = corners, missing: Int? = nil,
                       offset: (Int, Int) -> CGPoint = { _, _ in .zero }, duplicate: Bool = false) -> [WallMappingCheck.Frame] {
        let board = WallBoard(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])!
        let w = WallMappingCheck.width, h = WallMappingCheck.height
        var dark = [UInt8](repeating: 80, count: w * h)
        // A bright static object must cancel out of both blink differences.
        for y in 40..<65 { for x in 40..<85 { dark[y * w + x] = 230 } }
        func draw(_ point: CGPoint, into image: inout [UInt8]) {
            let x = Int(point.x * Double(w)), y = Int(point.y * Double(h))
            for yy in (y - 2)...(y + 2) where yy >= 0 && yy < h {
                for xx in (x - 2)...(x + 2) where xx >= 0 && xx < w { image[yy * w + xx] = 200 }
            }
        }
        var result: [WallMappingCheck.Frame] = []
        for pass in 0..<2 {
            var lit = dark
            for (index, target) in WallMappingCheck.points.enumerated() where index != missing {
                let point = board.imagePoint(u: target.x, v: target.y), shift = offset(pass, index)
                draw(CGPoint(x: point.x + shift.x / size.width, y: point.y + shift.y / size.height), into: &lit)
                if duplicate && index == 7 {
                    draw(board.imagePoint(u: target.x + 0.17, v: target.y), into: &lit)
                }
            }
            for frame in 0..<6 { result.append(.init(t: Double(pass * 6 + frame), luma: frame < 3 ? dark : lit)) }
        }
        return result
    }

    static func report(corners: [CGPoint]) -> WallMappingCheck.Report {
        WallMappingCheck.check(frames(corners: corners), on: on, off: off, corners: corners, size: size)
    }
}

@MainActor
extension WallTargetsModel {
    func validateMappingForTest() {
        beginMappingCheck()
        XCTAssertTrue(finishMappingCheck(WallMappingFixture.report(corners: corners)))
    }
}

@MainActor
final class WallMappingTests: XCTestCase {
    private let corners = WallMappingFixture.corners

    private func check(_ frames: [WallMappingCheck.Frame], corners: [CGPoint]? = nil) -> WallMappingCheck.Report {
        WallMappingCheck.check(frames, on: WallMappingFixture.on, off: WallMappingFixture.off,
                               corners: corners ?? self.corners, size: WallMappingFixture.size)
    }

    func testPerspectiveMapChecksEveryInteriorPointTwice() throws {
        let result = check(WallMappingFixture.frames())
        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.samples.count, 30)
        XCTAssertEqual(Set(result.samples.map(\.point)).count, 15)
        XCTAssertLessThan(try XCTUnwrap(result.maximumErrorPixels), 1.5)
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(WallMappingCheck.Report.self, from: data), result)
    }

    func testWrongMapCannotValidateItselfAgainstItsOwnPredictions() {
        let wrong = corners.map { CGPoint(x: $0.x + 16 / 1280, y: $0.y) }
        XCTAssertEqual(check(WallMappingFixture.frames(), corners: wrong).status, .misaligned)
    }

    func testInteriorDistortionIsDetectedDespiteCorrectOuterCorners() {
        let frames = WallMappingFixture.frames(offset: { _, index in index == 7 ? CGPoint(x: 14, y: 0) : .zero })
        XCTAssertEqual(check(frames).status, .misaligned)
    }

    func testMissingPointAndNoBlinkNeverUsePredictedCoordinates() {
        XCTAssertEqual(check(WallMappingFixture.frames(missing: 12)).status, .missingPoints)
        let dark = WallMappingFixture.frames()[0].luma
        XCTAssertEqual(check((0..<12).map { .init(t: Double($0), luma: dark) }).status, .missingPoints)
    }

    func testAmbiguousBlinkingReflectionDoesNotPickTheNearest() {
        XCTAssertEqual(check(WallMappingFixture.frames(duplicate: true)).status, .ambiguousPoints)
    }

    func testMovementBetweenBlinksIsNotAveragedIntoAGoodMap() {
        let frames = WallMappingFixture.frames(offset: { pass, _ in CGPoint(x: pass == 0 ? -3 : 3, y: 0) })
        XCTAssertEqual(check(frames).status, .unstable)
    }

    func testIncompleteMalformedOrInvalidGeometryCannotPass() {
        XCTAssertEqual(check(Array(WallMappingFixture.frames().dropLast())).status, .missingPoints)
        XCTAssertEqual(check((0..<12).map { .init(t: Double($0), luma: [0]) }).status, .missingPoints)
        XCTAssertEqual(check([], corners: []).status, .invalidGeometry)
    }

    func testScoringRequiresAnIndependentCheckAndChangingCornersInvalidatesIt() {
        let model = WallTargetsModel(defaults: UserDefaults(suiteName: "WallMapping.\(UUID())")!)
        model.setCorners(corners)
        model.finishReference(Array(repeating: 0.04, count: 6))
        XCTAssertFalse(model.startPlay())
        model.beginMappingCheck()
        XCTAssertFalse(model.startPlay())
        XCTAssertFalse(model.finishMappingCheck(check(WallMappingFixture.frames(missing: 0))))
        XCTAssertFalse(model.startPlay())
        model.validateMappingForTest()
        XCTAssertTrue(model.startPlay())
        model.setCorners(corners)
        XCTAssertNil(model.mappingReport)
        model.finishReference(Array(repeating: 0.04, count: 6))
        XCTAssertFalse(model.startPlay())
    }
}
#endif
