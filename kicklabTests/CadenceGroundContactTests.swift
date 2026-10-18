import Foundation
import Testing
@testable import kicklab

struct CadenceGroundContactTests {
    private final class Resources {}
    private struct Case: Decodable {
        let name: String
        let foot: FootContactEvidence?
        let ground: GroundContactEvidence?
        let expectedFoot: Bool?
        let expectedLegacyFoot: Bool?
        let expectedGround: Bool?
    }
    private func cases() throws -> [Case] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "cadence-ground-foot", withExtension: "json"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    @Test func recordedFootAndFloorCasesStaySeparate() throws {
        for item in try cases() {
            if let foot = item.foot {
                #expect(foot.confirms == (item.expectedLegacyFoot ?? false), "\(item.name): preserve original foot evidence")
                #expect(foot.confirmsExtendedMotion == item.expectedFoot, "\(item.name)")
            }
            if let ground = item.ground {
                #expect(!ground.confirmsGroundContact(corroboratingWeakAnkles: true))
                #expect(ground.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true) == item.expectedGround)
            }
        }
    }

    @Test func sparseGroundStillRequiresContinuousRealCoverageAndConfidentFeet() throws {
        let original = try #require(cases().compactMap(\.ground).first)
        for samples in [Array(original.samples.suffix(4)), Array(original.samples.dropLast()),
                        original.samples.filter { $0.timestampMs != original.contactMs }] {
            let changed = GroundContactEvidence(contactMs: original.contactMs, samples: samples, checksBallBelowFeet: true)
            #expect(!changed.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        }
        let weak = original.samples.map { s in
            var ankles = s.ankles
            if s.timestampMs == original.contactMs { ankles[.left]?.confidence = 0.49 }
            return GroundContactEvidence.Sample(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY,
                width: s.width, height: s.height, confidence: s.confidence, imageAspect: s.imageAspect,
                ankles: ankles, hips: s.hips)
        }
        #expect(!GroundContactEvidence(contactMs: original.contactMs, samples: weak, checksBallBelowFeet: true)
            .confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
    }

    @Test func laterRealReleaseIsRequiredWhenTheFirstSparseViewStillOverlapsTheFoot() throws {
        var foot = try #require(cases().first { $0.name == "current-test-fps15-phase0-58.48" }?.foot)
        #expect(foot.confirmsExtendedMotion)
        foot.continuation = nil
        #expect(!foot.confirmsExtendedMotion)
    }

    @Test func extendedFootCannotBeEstablishedByStationaryFeetOrWeakPose() throws {
        let original = try #require(cases().first { $0.name == "current-test-fps20-phase0-58.48" }?.foot)
        func stationary(_ s: FootContactRules.Sample) -> FootContactRules.Sample {
            .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY,
                  width: s.width, height: s.height, confidence: s.confidence,
                  ankles: original.contact.ankles, hips: original.contact.hips)
        }
        #expect(!FootContactEvidence(before: stationary(original.before), contact: original.contact,
                                     after: stationary(original.after)).confirmsExtendedMotion)
        var ankles = original.contact.ankles
        ankles[.left]?.confidence = 0.49
        let c = original.contact
        let weak = FootContactRules.Sample(timestampMs: c.timestampMs, ballX: c.ballX, ballY: c.ballY,
            width: c.width, height: c.height, confidence: c.confidence, ankles: ankles, hips: c.hips)
        #expect(!FootContactEvidence(before: original.before, contact: weak, after: original.after).confirmsExtendedMotion)
    }

    @Test func historicalConfigurationOmitsTheNewPolicyAndEvidenceSurvivesSerialization() throws {
        let old = try JSONDecoder().decode(CounterConfig.self, from: JSONEncoder().encode(CounterConfig()).removingCadenceFlag())
        #expect(old.cadenceAwareGroundContact == nil)
        for item in try cases() {
            if let e = item.foot {
                let restored = try JSONDecoder().decode(FootContactEvidence.self, from: JSONEncoder().encode(e))
                #expect(restored == e)
                #expect(restored.confirmsExtendedMotion == e.confirmsExtendedMotion)
            }
        }
    }
}

private extension Data {
    func removingCadenceFlag() throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: self) as? [String: Any])
        json.removeValue(forKey: "cadenceAwareGroundContact")
        return try JSONSerialization.data(withJSONObject: json)
    }
}
