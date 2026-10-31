import Foundation
import Testing
@testable import kicklab

struct MeasuredFootContactTests {
    private final class Resources {}
    private struct Row: Decodable {
        let id: String
        let contactMs: Int
        let samples: [FootPoseSample]
    }
    private func data(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    private func impact(_ row: Row, turning: Bool = true, low: Bool = true) -> Int? {
        ObservedLegContactRules.contactTime(row.samples, at: row.contactMs,
            usesTemporalEvidence: true, usesCadenceWindow: true, allowsNearSupportFoot: true,
            usesImageSupport: true, allowsTurningHip: turning, allowsLowToeDeparture: low)
    }

    @Test func plantedSupportCanCorroborateTurningHipDuringAVisibleSideKick() throws {
        let rows = try JSONDecoder().decode([Row].self, from: data("outdoor-measured-leg-20261027"))
        let turning = try #require(rows.first { $0.id == "test120-1465" })
        #expect(impact(turning, turning: false, low: false) == nil)
        #expect(impact(turning, low: false) == turning.contactMs)
        let low = try #require(rows.first { $0.id == "test120-1519" })
        #expect(impact(low, turning: false, low: false) == nil)
        #expect(impact(low, turning: false) == low.contactMs + 33)
        for row in rows {
            let noRelease = Row(id: row.id, contactMs: row.contactMs,
                samples: row.samples.filter { $0.pose.timestampMs <= row.contactMs })
            #expect(impact(noRelease) == nil)
            let stationary = Row(id: row.id, contactMs: row.contactMs,
                samples: row.samples.map { sample in
                    var s = sample
                    s.landmarks = row.samples[0].landmarks
                    return s
                })
            #expect(impact(stationary) == nil)
        }
    }

    @Test func weakMeasuredAnkleRequiresTwoSidedCorroboration() throws {
        let original = try JSONDecoder().decode(GroundContactEvidence.self, from: data("outdoor-weak-toe-20261027"))
        #expect(!original.confirmsCompactFootContact)
        var measured = original
        measured.corroboratesCompactAnkles = true
        #expect(measured.compactFootContactMs == original.contactMs - 33)
        let decoded = try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(measured))
        #expect(decoded == measured && decoded.confirmsCompactFootContact)
        measured.compactFootSamples = original.samples.filter { $0.timestampMs <= original.contactMs }
        #expect(!measured.confirmsCompactFootContact)
    }

    @Test func measuredAnkleRecoveryCannotTurnReviewedFloorBouncesIntoKicks() throws {
        for name in ["visible-ground-bounces-pose", "sparse-floor-bounces-pose"] {
            let rows = try JSONDecoder().decode([Int: GroundContactEvidence].self, from: data(name))
            for (frame, original) in rows {
                var measured = original
                measured.checksCompactFootContact = true
                measured.checksAdjacentCompactImpact = true
                measured.allowsSettlingCompactRelease = true
                measured.corroboratesCompactAnkles = true
                measured.usesMeasuredCompactRelease = true
                #expect(!measured.confirmsCompactFootContact, "\(name) frame \(frame)")
            }
        }
    }

    @Test func toeCanTravelWithBallBeforeTheObservedRelease() throws {
        struct Saved: Decodable { let id: String; let evidence: GroundContactEvidence }
        let rows = try JSONDecoder().decode([Saved].self, from: data("outdoor-measured-release-20261027"))
        for row in rows {
            var evidence = row.evidence
            #expect(!evidence.confirmsCompactFootContact, "\(row.id) baseline")
            evidence.usesMeasuredCompactRelease = true
            #expect(evidence.confirmsCompactFootContact, "\(row.id)")
            let impact = try #require(evidence.compactFootContactMs)
            evidence.compactFootSamples = (evidence.compactFootSamples ?? evidence.samples)
                .filter { $0.timestampMs <= impact + 67 }
            // A single departure view cannot prove this sparse release.
            if (evidence.compactFootSamples ?? []).filter({ $0.timestampMs > impact }).count < 2 {
                #expect(!evidence.confirmsCompactFootContact, "\(row.id)")
            }
        }
    }

    @Test func raisedLegProofRemainsAvailableOutsideThePlayerBox() throws {
        let row = try JSONDecoder().decode(Row.self, from: data("outdoor-measured-raised-20261027"))
        func sample(_ value: FootPoseSample) -> FootContactRules.Sample {
            let p = value.pose
            return .init(timestampMs: p.timestampMs, ballX: p.ball.x, ballY: p.ball.y,
                width: p.width, height: p.height, confidence: p.confidence,
                ankles: value.ankles,
                hips: Dictionary(uniqueKeysWithValues: BodySide.allCases.compactMap { side in
                    value.landmarks[side.hip].map { (side, $0) }
                }))
        }
        let center = try #require(row.samples.first { $0.pose.timestampMs == row.contactMs })
        var evidence = FootContactEvidence(before: sample(row.samples.first!), contact: sample(center),
            after: sample(row.samples.last!), observedLegSamples: row.samples)
        #expect(evidence.observedLegContactMs == nil)
        evidence.usesMeasuredFootProof = true
        #expect(evidence.observedLegContactMs == row.contactMs + 33)
        evidence.observedLegSamples = row.samples.filter { $0.pose.timestampMs <= row.contactMs }
        #expect(!evidence.confirms)
    }

    @Test func weakArmEstimateOnVisibleKneeReboundCannotSupplyAnArmVeto() throws {
        let row = try JSONDecoder().decode(Row.self, from: data("outdoor-knee-hand-20261027"))
        #expect(impact(row) == row.contactMs + 34)
        for sample in row.samples where (0...34).contains(sample.pose.timestampMs-row.contactMs) {
            let p = sample.pose
            #expect(JugglingContactRules.isHand(ball: p.ball, width: p.width, joints: p.joints))
            #expect(!JugglingContactRules.isHand(ball: p.ball, width: p.width, joints: p.joints,
                measuredArms: sample.landmarks))
            let strong = sample.landmarks.mapValues { value in
                PoseLandmark(x: value.x, y: value.y, confidence: 1)
            }
            // Reliable arm evidence at that location still vetoes the count.
            #expect(JugglingContactRules.isHand(ball: p.ball, width: p.width, joints: p.joints,
                measuredArms: strong))
        }
    }

    @Test func sideKickCanUseClearBallHeightWhenAnkleDoesNotRiseAboveSupport() throws {
        let rows = try JSONDecoder().decode([Row].self, from: data("outdoor-airborne-side-foot-20261027"))
        for row in rows {
            #expect(impact(row, low: false) == nil)
            #expect(impact(row) == row.contactMs)
            let noRelease = Row(id: row.id, contactMs: row.contactMs,
                samples: row.samples.filter { $0.pose.timestampMs <= row.contactMs })
            #expect(impact(noRelease) == nil)
            let stationary = Row(id: row.id, contactMs: row.contactMs,
                samples: row.samples.map { value in
                    var s = value
                    s.landmarks = row.samples[0].landmarks
                    return s
                })
            #expect(impact(stationary) == nil)
        }
    }
}
