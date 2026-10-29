import Foundation
import Testing
@testable import kicklab

struct CorroboratedFloorReboundTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        let id: String
        let reject: Bool
        var ground: GroundContactEvidence
    }
    private func fixtures() throws -> [Fixture] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-corroborated-floor-20261028", withExtension: "json"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }
    @Test func measuredFloorBounceIsRejectedWithoutLosingReviewedToeKicks() throws {
        for var f in try fixtures() {
            #expect(f.ground.corroboratedFloorReboundMs == nil)
            f.ground.checksCorroboratedFloorRebound = true
            #expect((f.ground.corroboratedFloorReboundMs != nil) == f.reject, Comment(rawValue: f.id))
            let encoded = try PropertyListEncoder().encode(f.ground)
            let decoded = try PropertyListDecoder().decode(GroundContactEvidence.self, from: encoded)
            #expect(decoded == f.ground)
            #expect(decoded.corroboratedFloorReboundMs == f.ground.corroboratedFloorReboundMs)
        }
        #expect(!MeasuredFootImpactPolicy.corroboratedFloor(arguments: []))
    }
    @Test func weakPoseCannotReplaceAnObservedMinimumOrInventAnAnkle() throws {
        for var f in try fixtures() where f.reject {
            f.ground.checksCorroboratedFloorRebound = true
            let impact = try #require(f.ground.corroboratedFloorReboundMs)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.ground)) as! [String:Any]
            let samples = object["samples"] as! [[String:Any]]
            for mutation in [0,1,2,3] {
                object["samples"] = samples.compactMap { original -> [String:Any]? in
                    var s = original
                    if mutation == 0 && s["timestampMs"] as? Int == impact { return nil }
                    if mutation == 1 { s["ankles"] = [String:Any]() }
                    if mutation == 2 { s["confidence"] = 0.4 }
                    if mutation == 3 {
                        var ankles = s["ankles"] as! [String:[String:Any]]
                        for side in ankles.keys { ankles[side]?["confidence"] = 0.45 }
                        s["ankles"] = ankles
                    }
                    return s
                }
                let g = try JSONDecoder().decode(GroundContactEvidence.self,from:JSONSerialization.data(withJSONObject:object))
                #expect(g.corroboratedFloorReboundMs == nil, Comment(rawValue: f.id+" mutation \(mutation)"))
            }
        }
    }
}
