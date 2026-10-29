import Foundation
import Testing
@testable import kicklab

struct SideOnFootContactTests {
    private final class Resources {}
    private struct Row: Decodable {
        struct View: Decodable {
            let timestampMs: Int
            let ball: [Double]
            let landmarks: [BodyJoint: [Double]]
            var sample: FootPoseSample {
                let points = landmarks.mapValues { PoseLandmark(x: $0[0], y: $0[1], confidence: $0[2]) }
                return .init(pose: .init(timestampMs: timestampMs, ball: .init(x: ball[0], y: ball[1]),
                    width: ball[2], height: ball[3], confidence: ball[4], imageAspect: ball[5],
                    joints: points.filter { $0.value.confidence >= 0.3 }.mapValues { .init(x: $0.x, y: $0.y) }),
                    ankles: [:], landmarks: points)
            }
        }
        let contactMs: Int
        let samples: [View]
    }
    private func fixture() throws -> Row {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "side-on-foot-20261019", withExtension: "json"))
        return try #require(JSONDecoder().decode([Row].self, from: Data(contentsOf: url)).first)
    }
    private func impact(_ samples: [FootPoseSample], at time: Int, imageSupport: Bool = true) -> Int? {
        ObservedLegContactRules.contactTime(samples, at: time, usesTemporalEvidence: true,
            usesCadenceWindow: true, allowsNearSupportFoot: true, usesImageSupport: imageSupport)
    }

    @Test func measuredSidewaysKickSurvivesProjectedHipMovement() throws {
        let row = try fixture(), samples = row.samples.map(\.sample)
        #expect(impact(samples, at: row.contactMs, imageSupport: false) == nil)
        #expect(impact(samples, at: row.contactMs) == row.contactMs + 33)
        // The original sparse track also contains a usable, observed release.
        // It must recover without increasing continuous model inference.
        #expect(impact(samples.filter { $0.pose.timestampMs != row.contactMs + 33 }, at: row.contactMs) == row.contactMs + 100)
    }

    @Test func stationaryMissingWeakOrUnreleasedFeetCannotUseImageSupport() throws {
        let row = try fixture(), samples = row.samples.map(\.sample)
        for kind in ["stationary", "missing", "weak", "floor", "noRelease"] {
            let changed = samples.compactMap { original -> FootPoseSample? in
                var s = original
                switch kind {
                case "stationary": s.landmarks = samples[0].landmarks
                case "missing": s.landmarks.removeValue(forKey: .rightAnkle)
                case "weak": s.landmarks = s.landmarks.mapValues { .init(x: $0.x, y: $0.y, confidence: 0.29) }
                case "floor":
                    let p = s.pose
                    s = .init(pose: .init(timestampMs: p.timestampMs, ball: .init(x: p.ball.x, y: 0.99),
                        width: p.width, height: p.height, confidence: p.confidence, imageAspect: p.imageAspect,
                        joints: p.joints), ankles: s.ankles, landmarks: s.landmarks)
                default: if s.pose.timestampMs > row.contactMs + 33 { return nil }
                }
                return s
            }
            #expect(impact(changed, at: row.contactMs) == nil, "\(kind)")
        }
    }

    @Test func observedLegProofSurvivesNumericTraceRoundTrip() throws {
        let row = try fixture(), views = row.samples.map(\.sample)
        let contact = try #require(views.first { $0.pose.timestampMs == row.contactMs })
        func sample(_ v: FootPoseSample) -> FootContactRules.Sample {
            .init(timestampMs: v.pose.timestampMs, ballX: v.pose.ball.x, ballY: v.pose.ball.y,
                  width: v.pose.width, height: v.pose.height, confidence: v.pose.confidence,
                  ankles: [:], hips: [:])
        }
        var evidence = FootContactEvidence(before: sample(views.first!), contact: sample(contact), after: sample(views.last!))
        #expect(!evidence.confirms)
        evidence.observedLegSamples = views
        #expect(evidence.observedLegContactMs == row.contactMs + 33)
        #expect(evidence.confirms)
        let decoded = try JSONDecoder().decode(FootContactEvidence.self, from: JSONEncoder().encode(evidence))
        #expect(decoded == evidence && decoded.confirms)
        evidence.observedLegSamples = views.filter { $0.pose.timestampMs <= row.contactMs + 33 }
        #expect(!evidence.confirms, "A nearby foot without an observed release is insufficient")
    }
}
