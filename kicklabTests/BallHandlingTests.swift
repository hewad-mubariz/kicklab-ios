import Foundation
import Testing
@testable import kicklab

struct BallHandlingTests {
    private func sample(_ time: Int, y: Double = 0.6, handsY: Double? = nil,
                        confidence: Double = 0.9) -> BallHandlingEvidence.Sample {
        .init(timestampMs: time, ball: .init(x: 0.5,y: y), width: 0.18,height: 0.1,
              confidence: 0.9,imageAspect: 0.5625,
              wrists: [.left: .init(x: 0.4,y: handsY ?? y-0.04,confidence: confidence),
                       .right: .init(x: 0.6,y: handsY ?? y-0.04,confidence: confidence)])
    }
    private var grip: [BallHandlingEvidence.Sample] {
        [-100,-50,0,50,100].map { sample($0,y: 0.6-Double($0)*0.0004) }
    }
    @Test func SustainedGripIncludesMovingPickup() {
        #expect(BallHandlingEvidence(contactMs: 0,samples: grip).state == .held)
        #expect(BallHandlingEvidence(contactMs: 0,samples: [-100,-50,0,50,100].map { sample($0) }).state == .held)
    }
    @Test func NearbyHandsWithoutBallCouplingCannotReject() {
        let passing = [-100,-50,0,50,100].map { sample($0,y: 0.6-Double($0)*0.001,handsY: 0.56) }
        #expect(BallHandlingEvidence(contactMs: 0,samples: passing).state != .held)
    }
    @Test func MissingWeakOrBriefEvidenceStaysUncertain() {
        for times in [[-100,0,100],[-100,-50,0],[0,50,100],[-200,0,50,100]] {
            #expect(BallHandlingEvidence(contactMs: 0,samples: times.map { sample($0) }).state == .uncertain)
        }
        #expect(BallHandlingEvidence(contactMs: 0,samples: [-100,-50,0,50,100].map { sample($0,confidence: 0.49) }).state == .uncertain)
        let missing = grip.map { s in
            BallHandlingEvidence.Sample(timestampMs: s.timestampMs,ball: s.ball,width: s.width,height: s.height,
                confidence: s.confidence,imageAspect: s.imageAspect,wrists: [.left: s.wrists[.left]!])
        }
        #expect(BallHandlingEvidence(contactMs: 0,samples: missing).state == .uncertain)
    }
    @Test func ReleaseAndNextKickHaveNoStickyHandlingState() {
        let held = BallHandlingEvidence(contactMs: 0,samples: grip)
        #expect(held.state == .held)
        let clear = [-100,-50,0,50,100].map { sample($0,y: 0.85,handsY: 0.45) }
        #expect(BallHandlingEvidence(contactMs: 0,samples: clear).state == .inPlay)
        // A real contact followed by a catch is not a grip at the contact.
        let catchAfter = [-100,-50,0,50,100].map { sample($0,y: 0.6,handsY: $0 <= 0 ? 0.4 : 0.56) }
        #expect(BallHandlingEvidence(contactMs: 0,samples: catchAfter).state != .held)
    }
    private final class Resources {}
    // Source 6B9D12FD-5B5A-404A-89AC-BB1B837EA657, SHA-256
    // bbb5eb2192f8d92972da29918bdc753683feb5feb247277f1984661872645e6d.
    // Phone Vision evidence + frame-by-frame visual labels. Feet include raised
    // inside/outside poses; exact foot surface is not inferred from pose alone.
    private struct ReviewedContact: Decodable {
        let frame: Int
        let label: String
        let evidence: BallHandlingEvidence
    }
    @Test func labelledPhoneContactsRejectTwoGripsAndPreserveReviewedTouches() throws {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "handling-device-contacts",withExtension: "json"))
        let rows = try JSONDecoder().decode([ReviewedContact].self,from: Data(contentsOf: url))
        #expect(rows.count == 21)
        #expect(rows.filter { $0.label == "pickup" || $0.label == "held" }.count == 2)
        for row in rows {
            #expect((row.evidence.state == .held) == ["pickup","held"].contains(row.label),
                    "Reviewed \(row.label) at frame \(row.frame)")
            var updated = row.evidence
            updated.bridgesGripJitter = true
            #expect((updated.state == .held) == ["pickup","held"].contains(row.label),
                    "Temporal grip: reviewed \(row.label) at frame \(row.frame)")
        }
        // The ground label is a known remaining false count, not a grip.
        // This fixture tests handling specificity, not complete count accuracy.
    }

    @Test func savedHandHoldSurvivesBriefWristJitterButNotMissingEvidence() throws {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "grip-jitter-20261024", withExtension: "json"))
        var evidence = try JSONDecoder().decode(BallHandlingEvidence.self, from: Data(contentsOf: url))
        #expect(evidence.state == .uncertain)
        evidence.bridgesGripJitter = true
        #expect(evidence.state == .held)
        #expect(try JSONDecoder().decode(BallHandlingEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
        let beforeOnly = evidence.samples.filter { $0.timestampMs <= evidence.contactMs }
        #expect(BallHandlingEvidence(contactMs: evidence.contactMs, samples: beforeOnly, bridgesGripJitter: true).state != .held)
        let missing = evidence.samples.map { s in
            BallHandlingEvidence.Sample(timestampMs: s.timestampMs, ball: s.ball, width: s.width, height: s.height,
                confidence: s.confidence, imageAspect: s.imageAspect,
                wrists: s.timestampMs == evidence.contactMs ? [:] : s.wrists)
        }
        #expect(BallHandlingEvidence(contactMs: evidence.contactMs, samples: missing, bridgesGripJitter: true).state != .held)
    }
    @Test func GripStartsWhenHandsActuallyCoupleAndCannotBridgeDuplicateTimes() {
        let approach = sample(-200,y: 0.56,handsY: 0.5)
        #expect(BallHandlingEvidence(contactMs: 0,samples: [approach]+grip).state == .held)
        #expect(BallHandlingEvidence(contactMs: 0,samples: grip+[grip[2]]).state == .uncertain)
    }

    @Test func SameSideHandsAndInvalidGeometryCannotClaimGrip() {
        let sameSide = grip.map { s in
            BallHandlingEvidence.Sample(timestampMs: s.timestampMs,ball: s.ball,width: s.width,height: s.height,
                confidence: s.confidence,imageAspect: s.imageAspect,
                wrists: [.left: .init(x: 0.6,y: s.ball.y),.right: .init(x: 0.65,y: s.ball.y)])
        }
        #expect(BallHandlingEvidence(contactMs: 0,samples: sameSide).state != .held)
        #expect(BallHandlingEvidence(contactMs: 0,samples: [-100,-50,0,50,100].map { sample($0,y: .nan) }).state == .uncertain)
    }
}
