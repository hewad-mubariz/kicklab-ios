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
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true))
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        let saved = try JSONEncoder().encode(evidence)
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: saved) == evidence)
    }

    @Test func reviewedFloorBouncesKeepTheirPositiveFloorEvidence() throws {
        for name in ["visible-ground-bounces-pose", "sparse-floor-bounces-pose"] {
            let rows = try read(name, as: [Int: GroundContactEvidence].self)
            for (frame, old) in rows where old.confirmsGroundContact(corroboratingWeakAnkles: true) {
                var current = old
                current.requiresLowBallCenter = true
                #expect(current.confirmsGroundContact(corroboratingWeakAnkles: true), "\(name) frame \(frame)")
            }
        }
    }
}
