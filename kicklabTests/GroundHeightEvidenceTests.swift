import Foundation
import Testing
@testable import kicklab

struct GroundHeightEvidenceTests {
    private final class Resources {}
    private func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @Test func visibleToeFlickAboveTheAnklesIsNotAFloorBounce() throws {
        var evidence = try read("foot-flick-20261019-ground", as: GroundContactEvidence.self)
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true))
        evidence.requiresLowBallCenter = true
        evidence.usesLocalImpactSize = true
        evidence.requiresPositiveLowContact = true
        #expect(!evidence.needsPositiveFootContact)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true))
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        let saved = try JSONEncoder().encode(evidence)
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: saved) == evidence)
    }

    @Test func missingFloorImpactIsUncertainUntilFootContactIsResolved() throws {
        for name in ["floor-gap-25-20261024", "floor-gap-26-20261024"] {
            var evidence = try read(name, as: GroundContactEvidence.self)
            #expect(!evidence.needsPositiveFootContact)
            #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
            evidence.requiresPositiveLowContact = true
            #expect(evidence.needsPositiveFootContact)
            // Requiring more proof must not invent a confirmed floor impact.
            #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
            #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
        }
    }

    @Test func denseLowJugglingDoesNotTakeTheSparseImpactRoute() throws {
        // Visually labelled legal low-corpus contact, frame 129. An ankle-height
        // rule alone rejected it despite every impact observation being present.
        var evidence = try read("low-dense-impact-20261025", as: GroundContactEvidence.self)
        evidence.requiresPositiveLowContact = true
        #expect(evidence.needsPositiveFootContact)
        evidence.requiresPositiveLowContact = GroundContactEvidence.hasImpactTrackingGap(
            contactMs: evidence.contactMs, originalTimestampsMs: evidence.samples.map(\.timestampMs),
            missingBallTimestampsMs: [])
        #expect(!evidence.needsPositiveFootContact)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
    }

    @Test func reviewedFloorBouncesKeepTheirPositiveFloorEvidence() throws {
        for name in ["visible-ground-bounces-pose", "sparse-floor-bounces-pose"] {
            let rows = try read(name, as: [Int: GroundContactEvidence].self)
            for (frame, old) in rows where old.confirmsGroundContact(corroboratingWeakAnkles: true) {
                var current = old
                current.requiresLowBallCenter = true
                current.usesLocalImpactSize = true
                #expect(current.confirmsGroundContact(corroboratingWeakAnkles: true), "\(name) frame \(frame)")
            }
        }
    }

    @Test func savedFloorBounceUsesLocalSizeButStillRequiresApproachAndRelease() throws {
        var evidence = try read("floor-size-20261024", as: GroundContactEvidence.self)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        evidence.usesLocalImpactSize = true
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        let missingRelease = GroundContactEvidence(contactMs: evidence.contactMs,
            samples: evidence.samples.filter { $0.timestampMs <= evidence.contactMs },
            checksBallBelowFeet: true, requiresLowBallCenter: true, usesLocalImpactSize: true)
        #expect(!missingRelease.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
    }

    @Test func existingFloorProofWithShortReleaseKeepsItsVerdict() throws {
        var evidence = try read("floor-short-release-20261024", as: GroundContactEvidence.self)
        #expect(evidence.confirmsBallBelowFeet)
        evidence.usesLocalImpactSize = true
        #expect(evidence.confirmsBallBelowFeet)
    }
}
