import XCTest
@testable import kicklab

final class ToeGroundRecoveryTests: XCTestCase {
    func sample(_ ms: Int, ballY: Double, footX: Double) -> FootContactRules.Sample {
        .init(timestampMs: ms, ballX: 0.50, ballY: ballY, width: 0.10, height: 0.08,
              confidence: 0.95,
              ankles: [.left: .init(x: footX, y: 0.68, confidence: 0.95),
                       .right: .init(x: 0.65, y: 0.70, confidence: 0.95)],
              hips: [.left: .init(x: 0.45, y: 0.45, confidence: 0.95),
                     .right: .init(x: 0.62, y: 0.45, confidence: 0.95)])
    }
    var kick: [FootContactRules.Sample] {
        [sample(900, ballY: 0.55, footX: 0.40), sample(1000, ballY: 0.65, footX: 0.44),
         sample(1067, ballY: 0.58, footX: 0.445), sample(1100, ballY: 0.54, footX: 0.445)]
    }
    func testResolvedFootProofPreservesNativeFloorEvidence() throws {
        let s = kick[0]
        var native = GroundContactEvidence(contactMs: 1000, samples: [
            .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY, width: s.width,
                  height: s.height, confidence: s.confidence, imageAspect: 0.5625, ankles: s.ankles, hips: s.hips)])
        native.checksUnliftedFloorRebound = true
        native.checksCorroboratedFloorRebound = true
        native.requiresMovingAnkleForRescue = true
        let recovered = try XCTUnwrap(ToeGroundRecovery.augment(native, with: kick, imageAspect: 0.5625))
        XCTAssertNotNil(recovered.visibleFootProof)
        XCTAssertEqual(recovered.samples, native.samples)
        XCTAssertEqual(recovered.checksUnliftedFloorRebound, true)
        XCTAssertEqual(recovered.checksCorroboratedFloorRebound, true)
        XCTAssertEqual(recovered.requiresMovingAnkleForRescue, true)
        XCTAssertEqual(recovered.compactFootSamples?.first?.imageAspect, 0.5625)
    }
    func testStationaryFeetDoNotTurnAReboundIntoATouch() {
        let samples = zip([900, 1000, 1067, 1100], [0.55, 0.65, 0.58, 0.54]).map {
            sample($0.0, ballY: $0.1, footX: 0.44)
        }
        XCTAssertNil(ToeGroundRecovery.augment(.init(contactMs: 1000, samples: []), with: samples, imageAspect: 0.5625))
    }
    func testMissingReleaseAndDuplicateExposureCannotProveContact() {
        let native = GroundContactEvidence(contactMs: 1000, samples: [])
        XCTAssertNil(ToeGroundRecovery.augment(native, with: Array(kick.prefix(3)), imageAspect: 0.5625))
        XCTAssertNil(ToeGroundRecovery.augment(native, with: kick+[kick[1]], imageAspect: 0.5625))
        XCTAssertNil(ToeGroundRecovery.augment(native, with: kick, imageAspect: .nan))
    }
    func testAfterImpactChasingDoesNotRescueFloorBounce() {
        var samples=kick
        samples[2]=sample(1067, ballY: 0.58, footX: 0.49)
        samples[3]=sample(1100, ballY: 0.54, footX: 0.52)
        XCTAssertNil(ToeGroundRecovery.augment(.init(contactMs: 1000, samples: []), with: samples, imageAspect: 0.5625))
    }
    func testOnlyExplicitToesMayArriveInsideBallBeforeBraking() {
        let samples=[sample(900, ballY: 0.55, footX: 0.47), sample(1000, ballY: 0.65, footX: 0.51),
                     sample(1067, ballY: 0.58, footX: 0.512), sample(1100, ballY: 0.54, footX: 0.513)]
        XCTAssertNil(VisibleForefootContactRules.proof(samples, proposedMs: 1000))
        XCTAssertNotNil(VisibleForefootContactRules.proof(samples, proposedMs: 1000, observesToes: true))
        var passing=samples
        passing[2]=sample(1067, ballY: 0.58, footX: 0.55)
        passing[3]=sample(1100, ballY: 0.54, footX: 0.58)
        XCTAssertNil(VisibleForefootContactRules.proof(passing, proposedMs: 1000, observesToes: true))
    }
}
