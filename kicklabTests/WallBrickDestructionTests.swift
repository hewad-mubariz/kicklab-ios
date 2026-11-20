#if DEBUG
import XCTest
@testable import kicklab

final class WallBrickDestructionTests: XCTestCase {
    func testEllipseDistanceRejectsBoundingBoxCornerAndHandlesRotation() {
        let circle = WallContactFootprint(xAxis: CGPoint(x: 0.1, y: 0), yAxis: CGPoint(x: 0, y: 0.1))
        let rect = CGRect(x: 0.58, y: 0.58, width: 0.1, height: 0.1), p = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(circle.distance(to: rect, from: p), sqrt(1.28), accuracy: 0.0001)
        let rotated = WallContactFootprint(xAxis: CGPoint(x: 0.06, y: 0.08), yAxis: CGPoint(x: -0.08, y: 0.06))
        XCTAssertEqual(rotated.distance(to: rect, from: p), circle.distance(to: rect, from: p), accuracy: 0.0001)
    }
    func testMeasuredFootprintPreservesAffinePerspectiveAndResolution() throws {
        for scale in [1.0, 2.0] {
            let board = try XCTUnwrap(WallBoard(topLeft: CGPoint(x: 100 * scale, y: 100 * scale),
                topRight: CGPoint(x: 1000 * scale, y: 200 * scale), bottomRight: CGPoint(x: 1100 * scale, y: 800 * scale),
                bottomLeft: CGPoint(x: 200 * scale, y: 700 * scale)))
            let point = board.imagePoint(u: 1.5, v: 1)
            let f = try XCTUnwrap(WallContactFootprint.measured(board: board, point: point, diameter: 60 * scale))
            let edge = board.boardPoint(CGPoint(x: point.x + 30 * scale, y: point.y))
            XCTAssertEqual(edge.x - 1.5, f.xAxis.x, accuracy: 0.0001)
            XCTAssertEqual(edge.y - 1, f.xAxis.y, accuracy: 0.0001)
            XCTAssertEqual(abs(f.determinant), 0.0101886792453, accuracy: 0.00001)
        }
    }
    func testCoreShattersHaloCracksAndEmptyMaterialStaysGone() {
        let layout = WallTargetLayout(id: "test", targets: [
            .init(id: 1, frame: CGRect(x: 0.95, y: 0.95, width: 0.1, height: 0.1), health: 2, faceInset: 0),
            .init(id: 2, frame: CGRect(x: 1.15, y: 0.95, width: 0.1, height: 0.1), health: 2, faceInset: 0),
            .init(id: 3, frame: CGRect(x: 1.3, y: 0.95, width: 0.1, height: 0.1), health: 2, faceInset: 0)
        ], continuousSurface: true)
        let f = WallContactFootprint(xAxis: CGPoint(x: 0.1, y: 0), yAxis: CGPoint(x: 0, y: 0.1))
        let hit = WallBrickDestruction.damage(at: CGPoint(x: 1, y: 1), footprint: f, layout: layout, health: [:])
        XCTAssertEqual(hit, [.init(id: 1, before: 2, after: 0), .init(id: 2, before: 2, after: 1)])
        let again = WallBrickDestruction.damage(at: CGPoint(x: 1, y: 1), footprint: f, layout: layout, health: [1: 0, 2: 1])
        XCTAssertEqual(again, [.init(id: 2, before: 1, after: 0)])
    }
    func testInternalSeamsArePlayableButOuterBoundaryRemainsUncertain() throws {
        let board = try XCTUnwrap(WallBoard(topLeft: .zero, topRight: CGPoint(x: 1200, y: 0),
            bottomRight: CGPoint(x: 1200, y: 800), bottomLeft: CGPoint(x: 0, y: 800)))
        XCTAssertTrue(board.isBorderline(CGPoint(x: 400, y: 200), uncertainty: 10))
        XCTAssertFalse(board.isBorderline(CGPoint(x: 400, y: 200), uncertainty: 10, layout: .brickWall))
        XCTAssertTrue(board.isBorderline(CGPoint(x: 4, y: 200), uncertainty: 10, layout: .brickWall))
        XCTAssertTrue(board.isBorderline(CGPoint(x: -20, y: 200), uncertainty: 10, layout: .brickWall))
    }
}
#endif
