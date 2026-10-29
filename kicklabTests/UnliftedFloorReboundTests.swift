import Foundation
import Testing
@testable import kicklab

struct UnliftedFloorReboundTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        let id: String
        let reject: Bool
        var ground: GroundContactEvidence
    }
    private func fixtures() throws -> [Fixture] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-unlifted-floor-20261028", withExtension: "json"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }
    @Test func rejectsReviewedBouncesAndPreservesRecoveredContacts() throws {
        for var f in try fixtures() {
            #expect(f.ground.unliftedFloorReboundMs == nil, Comment(rawValue: f.id))
            f.ground.checksUnliftedFloorRebound = true
            #expect((f.ground.unliftedFloorReboundMs != nil) == f.reject, Comment(rawValue: f.id))
        }
    }
    @Test func sparseOrUncertainEvidenceCannotProveFloor() throws {
        for f in try fixtures() where f.reject {
            var g = f.ground; g.checksUnliftedFloorRebound = true
            // Removing the true minimum cannot be repaired by inventing it.
            let impact = try #require(g.unliftedFloorReboundMs)
            g = copy(g, samples: g.samples.filter { $0.timestampMs != impact })
            #expect(g.unliftedFloorReboundMs == nil)
            g = f.ground; g.checksUnliftedFloorRebound = true
            g = copy(g, samples: Array(g.samples.suffix(3)))
            #expect(g.unliftedFloorReboundMs == nil)
            g = f.ground; g.checksUnliftedFloorRebound = true
            g = copy(g, samples: g.samples.map { s in
                .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY,
                      width: s.width, height: s.height, confidence: 0.4,
                      imageAspect: s.imageAspect, ankles: s.ankles, hips: s.hips)
            })
            #expect(g.unliftedFloorReboundMs == nil)
        }
    }
    @Test func missingPoseAndDuplicateFramesStayInconclusive() throws {
        let all = try fixtures()
        let firstNegative = all.first { $0.reject }
        var g = try #require(firstNegative).ground
        g.checksUnliftedFloorRebound = true
        let duplicate = copy(g, samples: g.samples + [g.samples[0]])
        #expect(duplicate.unliftedFloorReboundMs == nil)
        let noPose = copy(g, samples: g.samples.map { s in
            .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY,
                  width: s.width, height: s.height, confidence: s.confidence,
                  imageAspect: s.imageAspect, ankles: [:], hips: [:])
        })
        #expect(noPose.unliftedFloorReboundMs == nil)
    }
    @Test func defaultOffAndEvidenceRoundTrips() throws {
        #expect(!UnliftedFloorReboundPolicy.enabled(arguments: []))
        for var f in try fixtures() {
            f.ground.checksUnliftedFloorRebound = true
            let data = try PropertyListEncoder().encode(f.ground)
            let decoded = try PropertyListDecoder().decode(GroundContactEvidence.self, from: data)
            #expect(decoded == f.ground)
            #expect(decoded.unliftedFloorReboundMs == f.ground.unliftedFloorReboundMs)
        }
    }
    private func copy(_ g: GroundContactEvidence, samples: [GroundContactEvidence.Sample]) -> GroundContactEvidence {
        // Preserve every versioned field while replacing only recorded views.
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
        object["samples"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))
        return try! JSONDecoder().decode(GroundContactEvidence.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
