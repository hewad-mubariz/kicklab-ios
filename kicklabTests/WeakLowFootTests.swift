import Foundation
import Testing
@testable import kicklab

struct WeakLowFootTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        let id: String
        let needsProof: Bool
        var ground: GroundContactEvidence?
        var foot: FootContactEvidence?
    }
    private func fixtures() throws -> [Fixture] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-weak-low-foot-20261029", withExtension: "json"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }
    @Test func weakAnkleBelowBallCannotRescueKnownFloorControl() throws {
        let f = try #require(fixtures().first { $0.id == "false-paced" })
        var foot = try #require(f.foot)
        #expect(foot.confirms)
        foot.rejectsWeakBelowAnkle = true
        #expect(!foot.confirms)
        #expect(!FootContactRules.confirms(before: foot.before, contact: foot.contact, after: foot.after,
            rejectsWeakBelowAnkle: true))
        let decoded = try PropertyListDecoder().decode(FootContactEvidence.self,
            from: PropertyListEncoder().encode(foot))
        #expect(decoded == foot)
        #expect(!decoded.confirms)
        #expect(!WeakLowFootPolicy.enabled(arguments: []))
    }
    @Test func uncertaintyRequestsEvidenceWithoutCallingItAGroundBounce() throws {
        for f in try fixtures() {
            if var ground = f.ground {
                let before = ground.needsPositiveFootContact
                let floorBefore = ground.confirmsGroundContact(corroboratingWeakAnkles: true)
                ground.requiresResolvedLowFoot = true
                #expect(ground.hasWeakFootBesideLowBall == f.needsProof, Comment(rawValue: f.id))
                #expect(ground.needsPositiveFootContact == (before || f.needsProof), Comment(rawValue: f.id))
                #expect(ground.confirmsGroundContact(corroboratingWeakAnkles: true) == floorBefore)
                #expect(try PropertyListDecoder().decode(GroundContactEvidence.self,
                    from: PropertyListEncoder().encode(ground)) == ground)
            }
            if !f.needsProof, var foot = f.foot {
                let before = foot.confirms
                foot.rejectsWeakBelowAnkle = true
                #expect(foot.confirms == before, Comment(rawValue: f.id))
            }
        }
    }
    @Test func uncertainOrMissingSupportCannotSupplyTheNewGeometry() throws {
        let fixture = try #require(fixtures().first { $0.id == "false-original" })
        let ground = try #require(fixture.ground)
        #expect(ground.hasWeakFootBesideLowBall)
        let noSupport = GroundContactEvidence(contactMs: ground.contactMs, samples: ground.samples.map { s in
            .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY, width: s.width,
                height: s.height, confidence: s.confidence, imageAspect: s.imageAspect,
                ankles: s.ankles.filter { $0.key != .right }, hips: s.hips)
        })
        #expect(!noSupport.hasWeakFootBesideLowBall)
        let noRelease = GroundContactEvidence(contactMs: ground.contactMs,
            samples: ground.samples.filter { $0.timestampMs <= ground.contactMs })
        #expect(!noRelease.hasWeakFootBesideLowBall)
        let duplicate = GroundContactEvidence(contactMs: ground.contactMs,
            samples: ground.samples + [try #require(ground.samples.first)])
        #expect(!duplicate.hasWeakFootBesideLowBall)
    }
}
