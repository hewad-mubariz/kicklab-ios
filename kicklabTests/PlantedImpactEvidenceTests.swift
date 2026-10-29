import Foundation
import Testing
@testable import kicklab

struct PlantedImpactEvidenceTests {
    private final class Resources {}
    private func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @Test func excludedImpactCannotProveAPlantedStance() throws {
        var g = try read("outdoor-planted-impact-20261028", as: GroundContactEvidence.self)
        #expect(g.confirmsPlantedFeet(corroboratingWeakAnkles: true))
        #expect(g.confirmsGroundContact(corroboratingWeakAnkles: true))
        g.requiresPlantedImpactEvidence = true
        #expect(g.hasUncertainPlantedImpact)
        #expect(!g.confirmsGroundContact(corroboratingWeakAnkles: true))
        #expect(g.needsPositiveFootContact)
        let samples = (g.compactFootSamples ?? g.samples).map {
            FootContactRules.Sample(timestampMs: $0.timestampMs, ballX: $0.ballX, ballY: $0.ballY,
                width: $0.width, height: $0.height, confidence: $0.confidence, ankles: $0.ankles, hips: $0.hips)
        }
        let foot = try #require(AdjacentFootContactRules.measuredEvidence(samples, proposedMs: g.contactMs))
        #expect(foot.confirms)
        #expect(foot.contact.timestampMs == 34531)
    }

    @Test func poseUncertaintyStillRequiresFootProofWithoutATrackingGap() throws {
        var g = try read("outdoor-planted-impact-20261028", as: GroundContactEvidence.self)
        g.requiresPositiveLowContact = nil
        #expect(!g.needsPositiveFootContact)
        g.requiresPlantedImpactEvidence = true
        #expect(g.needsPositiveFootContact)
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(g)) == g)
    }

    @Test func knownFloorEvidenceRemainsAFloorOrRequiresPositiveFootProof() throws {
        for name in ["visible-ground-bounces-pose", "sparse-floor-bounces-pose"] {
            let rows = try read(name, as: [Int: GroundContactEvidence].self)
            for (frame, old) in rows where old.confirmsGroundContact(corroboratingWeakAnkles: true) {
                var g = old
                g.requiresPlantedImpactEvidence = true
                #expect(g.confirmsGroundContact(corroboratingWeakAnkles: true) || g.needsPositiveFootContact,
                        "Uncertain floor must not become an automatic count: \(name) / \(frame)")
            }
        }
    }

    @Test func measuredFloorAndOtherGroundProofsArePreserved() throws {
        var g = try read("floor-size-20261024", as: GroundContactEvidence.self)
        g.usesLocalImpactSize = true
        #expect(g.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        g.requiresPlantedImpactEvidence = true
        #expect(g.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        for name in ["floor-beside-3260-20261025", "floor-beside-490-20261025"] {
            var beside = try read(name, as: GroundContactEvidence.self)
            beside.checksBallBesideFeet = true
            beside.requiresPlantedImpactEvidence = true
            #expect(beside.confirmsBallBesideFeet)
        }
    }

    @Test func diagnosticFlagIsOffByDefaultAndLegacyEvidenceIsUnchanged() throws {
        #expect(!GroundImpactEvidencePolicy.enabled(arguments: []))
        let g = try read("outdoor-planted-impact-20261028", as: GroundContactEvidence.self)
        #expect(g.requiresPlantedImpactEvidence == nil)
        #expect(!g.hasUncertainPlantedImpact)
        #expect(g.confirmsGroundContact(corroboratingWeakAnkles: true))
    }
}
