#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallMotionSearchTests: XCTestCase {
    private let size = CGSize(width: 1280, height: 720)
    private func picture(ballX: Int? = nil, level: UInt8 = 65) -> [UInt8] {
        var image = [UInt8](repeating: level, count: 320 * 180)
        if let x = ballX {
            for y in 45..<65 { for dx in 0..<20 { image[y * 320 + x + dx] = 180 } }
        }
        return image
    }
    private func next(_ search: inout WallBallMotionSearch, _ pixels: [UInt8], _ time: Double) -> WallBallMotionSearch.Hint? {
        search.crop(luma: pixels, width: 320, height: 180, imageSize: size, at: time)
    }

    func testFindsIncomingBallOutsideBoardAndDoesNotChaseItsDepartedPosition() throws {
        var search = WallBallMotionSearch()
        XCTAssertNil(next(&search, picture(), 0))
        XCTAssertNil(next(&search, picture(), 0.1))
        let first = try XCTUnwrap(next(&search, picture(ballX: 20), 0.2))
        XCTAssertTrue(first.region.contains(CGPoint(x: 120, y: 220)))
        let second = try XCTUnwrap(next(&search, picture(ballX: 65), 0.3))
        XCTAssertTrue(second.region.contains(CGPoint(x: 300, y: 220)))
        XCTAssertFalse(second.region.contains(CGPoint(x: 120, y: 220)))
        XCTAssertNil(next(&search, picture(), 0.4))
    }

    func testStaticSceneFlashAndDiscontinuityDoNotSupplyASearchTarget() {
        var search = WallBallMotionSearch()
        for t in [0.0, 0.1, 0.2, 0.3] { XCTAssertNil(next(&search, picture(), t)) }
        XCTAssertNil(next(&search, picture(level: 130), 0.4))
        XCTAssertNil(next(&search, picture(ballX: 100), 1.0))
        XCTAssertNil(next(&search, picture(ballX: 100), 1.1))
        search.reset()
        XCTAssertNil(next(&search, picture(ballX: 100), 1.2))
    }

    func testMotionHintRequiresAModelBoxAtTheMovingRegion() throws {
        var search = WallBallMotionSearch()
        _ = next(&search, picture(), 0); _ = next(&search, picture(), 0.1)
        let hint = try XCTUnwrap(next(&search, picture(ballX: 40), 0.2))
        XCTAssertTrue(hint.contains(.init(score: 0.9, x: 200 / 1280, y: 220 / 720,
            width: 80 / 1280, height: 80 / 720), size: size, minimumDiameter: 25))
        XCTAssertFalse(hint.contains(.init(score: 0.9, x: 350 / 1280, y: 350 / 720,
            width: 40 / 1280, height: 40 / 720), size: size, minimumDiameter: 25))
        XCTAssertFalse(hint.contains(.init(score: 0.9, x: 200 / 1280, y: 220 / 720,
            width: 15 / 1280, height: 15 / 720), size: size, minimumDiameter: 25))
    }

    func testRecoveredRecordedShotsUseTheReviewedSquareOnce() throws {
        for scenario in try fixture() where scenario.expectedBox != nil {
            let hits = try replay(scenario)
            XCTAssertEqual(hits.count, 1, scenario.name)
            XCTAssertEqual(hits.first?.box, scenario.expectedBox, scenario.name)
            XCTAssertEqual(hits.first?.t ?? 0, scenario.expectedTime, accuracy: 0.01, scenario.name)
        }
    }

    func testRecoveredShotsStillRequireFreeFlightAndReturnEvidence() throws {
        for scenario in try fixture() where scenario.expectedBox != nil {
            for mode in ["held", "unknown", "no_return"] {
                XCTAssertTrue(try replay(scenario, mode: mode).isEmpty, "\(scenario.name): \(mode)")
            }
        }
    }

    func testChangingCadenceCannotResurrectAnOldUnconfirmedShot() throws {
        let scenario = try XCTUnwrap(try fixture().first { $0.name == "stale_contact_when_cadence_changes" })
        XCTAssertTrue(try replay(scenario).isEmpty)
    }

    func testSlowInferenceCannotJoinMissingWallContactToLaterFloorBounce() throws {
        let scenario = try XCTUnwrap(try fixture().first { $0.name == "stale_contact_when_cadence_changes" })
        for rate in [6.0, 8.0, 10.0] {
            XCTAssertTrue(try replay(scenario, overrideFPS: rate).isEmpty, "\(rate) fps")
        }
    }

    func testRecordedSparseShotsReachAllNineSquaresIncludingLateOuterShots() throws {
        for scenario in try fixture("wall-sparse-cadence") {
            let hits = try replay(scenario)
            XCTAssertEqual(hits.count, 1, scenario.name)
            XCTAssertEqual(hits.first?.box, scenario.expectedBox, scenario.name)
            XCTAssertEqual(hits.first?.t ?? 0, scenario.expectedTime, accuracy: 0.01, scenario.name)
        }
    }

    func testSparseShotsRequireReleaseAndActualReturn() throws {
        for scenario in try fixture("wall-sparse-cadence") {
            for mode in ["held", "unknown", "no_return"] {
                XCTAssertTrue(try replay(scenario, mode: mode).isEmpty, "\(scenario.name): \(mode)")
            }
        }
    }

    func testOneApproachSampleRequiresThreeStrongReturnMeasurements() throws {
        let scenario = try XCTUnwrap(try fixture("wall-sparse-cadence").first { $0.expectedBox == 3 })
        let c = scenario.corners.map { CGPoint(x: $0[0] * 1280, y: $0[1] * 720) }
        let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
        let measured = scenario.frames.filter { $0[1] > 0 && $0[0] <= scenario.expectedTime + 0.45 }
        XCTAssertEqual(measured.count, 5) // one approach, contact, three returns
        for returnCount in 0...3 {
            var detector = WallImpactDetector(board: board, reference: WallBallReference(scenario.reference),
                imageWidth: 1280, layout: .crossCircle)
            detector.processingFPS = 10; detector.usesSparseDepthConsistency = true
            for r in measured.prefix(2 + returnCount) {
                detector.add(.init(t: r[0], x: r[2], y: r[3], d: r[4], hand: .clear))
            }
            XCTAssertEqual(detector.impacts(now: scenario.expectedTime + 0.6).count, returnCount == 3 ? 1 : 0)
        }
    }

    private struct Scenario: Decodable {
        let name: String
        let expectedTime: Double
        let expectedBox: Int?
        let corners: [[Double]]
        let reference: [Double]
        let frames: [[Double]]
    }
    private func fixture(_ name: String = "wall-motion-acquisition") throws -> [Scenario] {
        struct Fixture: Decodable { let scenarios: [Scenario] }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path)).scenarios
    }
    private func replay(_ scenario: Scenario, mode: String = "original", overrideFPS: Double? = nil) throws -> [WallImpactDetector.Impact] {
        let c = scenario.corners.map { CGPoint(x: $0[0] * 1280, y: $0[1] * 720) }
        let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
        var detector = WallImpactDetector(board: board, reference: WallBallReference(scenario.reference),
            imageWidth: 1280, layout: .crossCircle)
        detector.usesSparseDepthConsistency = true
        detector.rejectBorderline = true
        var hits: [WallImpactDetector.Impact] = []
        for row in scenario.frames {
            detector.processingFPS = overrideFPS ?? row[6]
            if row[1] > 0, !(mode == "no_return" && row[0] > scenario.expectedTime + 0.001) {
                let hand = mode == "held" ? WallHandState.held : mode == "unknown" ? .unknown : WallHandState(rawValue: Int(row[5]))!
                detector.add(.init(t: row[0], x: row[2], y: row[3], d: row[4], hand: hand))
            }
            hits += detector.impacts(now: row[0])
        }
        return hits
    }
}
#endif
