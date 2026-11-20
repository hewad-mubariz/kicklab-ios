#if DEBUG
import XCTest
@testable import kicklab

final class WallImpactMotionTests: XCTestCase {
    private func samples(speed: Double, fps: Double = 60, scale: Double = 1) -> [WallImpactDetector.Observation] {
        (0...Int(0.2 * fps)).map { i in
            let t = Double(i) / fps
            return .init(t: t, x: (300 + speed * 40 * t) * scale, y: 200 * scale,
                         d: 40 * scale, hand: .clear)
        }
    }
    func testEstimateIsInvariantToImageResolutionAndCadence() throws {
        for fps in [15.0, 30, 60] { for scale in [0.5, 1, 2] {
            let s = samples(speed: 12, fps: fps, scale: scale)
            XCTAssertEqual(try XCTUnwrap(WallImpactMotion.approachSpeed(s, contact: s.last!)), 12, accuracy: 0.001)
        }}
    }
    func testFastApproachHasLargerBoundedEffect() throws {
        let slow = samples(speed: 3), fast = samples(speed: 24)
        let low = WallImpactMotion.strength(for: WallImpactMotion.approachSpeed(slow, contact: slow.last!))
        let high = WallImpactMotion.strength(for: WallImpactMotion.approachSpeed(fast, contact: fast.last!))
        XCTAssertLessThan(low, high)
        XCTAssertGreaterThanOrEqual(low, 0.45)
        XCTAssertEqual(high, 1)
        XCTAssertEqual(WallImpactMotion.strength(for: 10000), 1)
    }
    func testMissingHandEvidenceGapsJumpsAndInvalidDataUseNeutralEffect() {
        let good = samples(speed: 12)
        var hand = good; hand[4].hand = .unknown
        var jump = good; jump[5].x += 300
        var invalid = good; invalid[5].x = .nan
        var duplicate = good; duplicate[5].t = duplicate[4].t
        let gap = Array(good.prefix(3)) + Array(good.suffix(3))
        for s in [hand, jump, invalid, duplicate, gap, Array(good.suffix(2))] {
            XCTAssertNil(WallImpactMotion.approachSpeed(s, contact: s.last!))
        }
        for speed: Double? in [nil, .nan, .infinity, -1] {
            XCTAssertEqual(WallImpactMotion.strength(for: speed), 0.65)
        }
    }
    func testOutgoingSamplesCannotInflateIncomingMotion() throws {
        let s = samples(speed: 5), contact = s.last!
        let after = (1...6).map { i in WallImpactDetector.Observation(
            t: contact.t + Double(i) / 60, x: 2000, y: 2000, d: 40, hand: .clear) }
        XCTAssertEqual(try XCTUnwrap(WallImpactMotion.approachSpeed(s + after, contact: contact)), 5, accuracy: 0.001)
    }
}
#endif
