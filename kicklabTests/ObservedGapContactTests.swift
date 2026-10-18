import Foundation
import Testing
@testable import kicklab

struct ObservedGapContactTests {
    private final class Resources {}
    private struct Row: Decodable {
        struct View: Decodable {
            var timestampMs: Int
            var ball: [Double]
            var joints: [BodyJoint: [Double]]
            var landmarks: [BodyJoint: [Double]]
            var ankles: [BodySide: [Double]]
            var sample: FootPoseSample {
                .init(pose: .init(timestampMs: timestampMs,ball: .init(x:ball[0],y:ball[1]),
                    width:ball[2],height:ball[3],confidence:ball[4],imageAspect:ball[5],
                    joints:joints.mapValues { .init(x:$0[0],y:$0[1]) }),
                    ankles:ankles.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) },
                    landmarks:landmarks.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) })
            }
        }
        let id: String
        let contactMs: Int
        let samples: [View]
    }
    private func rows() throws -> [Row] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "final30-gap-evidence",withExtension: "json"))
        return try JSONDecoder().decode([Row].self,from:Data(contentsOf:url))
    }

    @Test func recordedFootContactsUseTheirActualBracketedLegObservations() throws {
        for row in try rows() {
            let result = ObservedGapContactRules.contactTime(row.samples.map(\.sample),at:row.contactMs)
            #expect(result != nil, "Reviewed foot contact \(row.id)")
            #expect(row.samples.contains { $0.timestampMs == result })
        }
    }

    @Test(arguments: ["missingLeg", "stationaryFoot", "loweringHips", "longGap", "belowFeet", "noAfter", "weakBall"])
    func uncertainOrFloorEvidenceCannotRecoverContact(change: String) throws {
        for row in try rows() {
            let before = try #require(row.samples.last { $0.timestampMs < row.contactMs })
            let samples = row.samples.compactMap { original -> FootPoseSample? in
                var s = original
                if change == "noAfter", s.timestampMs > row.contactMs { return nil }
                if change == "longGap" { s.timestampMs = row.contactMs+(s.timestampMs-row.contactMs)*5 }
                if change == "missingLeg" { s.landmarks = [:] }
                if change == "weakBall" { s.ball[4] = 0.39 }
                if change == "belowFeet" { s.ball[1] = 0.99 }
                if change == "stationaryFoot" || change == "loweringHips" {
                    for side in BodySide.allCases {
                        s.landmarks[side.ankle] = before.landmarks[side.ankle]
                        s.landmarks[side.hip] = before.landmarks[side.hip]
                        if change == "loweringHips", s.timestampMs > row.contactMs {
                            s.landmarks[side.hip]?[1] += 0.02
                        }
                    }
                }
                return s.sample
            }
            #expect(ObservedGapContactRules.contactTime(samples,at:row.contactMs) == nil)
        }
    }

    @Test func observedFloorBounceRequiresBothAnklesAndKeepsHistoricalReplay() throws {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "final30-floor-evidence",withExtension: "json"))
        var evidence = try JSONDecoder().decode(GroundContactEvidence.self,from:Data(contentsOf:url))
        #expect(!evidence.confirmsPlantedFeet(corroboratingWeakAnkles:true))
        #expect(evidence.confirmsBallBelowFeet)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles:true))
        evidence.checksBallBelowFeet = true
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles:true))
        let noAnkles = evidence.samples.map { s in
            GroundContactEvidence.Sample(timestampMs:s.timestampMs,ballX:s.ballX,ballY:s.ballY,
                width:s.width,height:s.height,confidence:s.confidence,imageAspect:s.imageAspect,
                ankles:[:],hips:s.hips)
        }
        #expect(!GroundContactEvidence(contactMs:evidence.contactMs,samples:noAnkles,
            checksBallBelowFeet:true).confirmsGroundContact(corroboratingWeakAnkles:true))
    }
}
