import Foundation
import Testing
@testable import kicklab

struct ReciprocalJointContactTests {
    private final class Resources {}
    private struct Window: Decodable {
        struct Sample: Decodable {
            let timestampMs: Int
            let ball: [Double]
            let landmarks: [BodyJoint: [Double]]
            var value: FootPoseSample {
                let points = landmarks.mapValues { PoseLandmark(x: $0[0], y: $0[1], confidence: $0[2]) }
                return .init(pose: .init(timestampMs: timestampMs, ball: .init(x: ball[0], y: ball[1]),
                    width: ball[2], height: ball[3], confidence: ball[4], imageAspect: ball[5],
                    joints: points.filter { $0.value.confidence >= 0.3 }.mapValues { .init(x: $0.x,y: $0.y) }),
                    ankles: Dictionary(uniqueKeysWithValues: BodySide.allCases.compactMap { side in
                        points[side.ankle].map { (side,$0) }
                    }), landmarks: points)
            }
        }
        let frame, contactMs: Int
        let label: String
        let samples: [Sample]
    }
    @Test func measuredReciprocalExchangeRecoversTheFootButPreservesHandControls() throws {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "reciprocal-joints-20261024", withExtension: "json"))
        let rows = try JSONDecoder().decode([Window].self, from: Data(contentsOf: url))
        #expect(rows.count >= 4)
        for row in rows {
            let samples = row.samples.map(\.value)
            #expect((ReciprocalJointContactRules.contactTime(samples, at: row.contactMs) != nil) == (row.label == "foot"),
                    "Reviewed \(row.label) at frame \(row.frame)")
            guard row.label == "foot" else { continue }
            #expect(ReciprocalJointContactRules.contactTime(samples.filter { $0.pose.timestampMs <= row.contactMs }, at: row.contactMs) == nil)
            var missing = samples
            let index = try #require(missing.firstIndex { $0.pose.timestampMs == row.contactMs })
            missing[index].landmarks.removeValue(forKey: .rightAnkle)
            #expect(ReciprocalJointContactRules.contactTime(missing, at: row.contactMs) == nil)
            var unrelated = samples
            unrelated[index].landmarks[.rightAnkle] = .init(x: 0.1,y: 0.6,confidence: 0.2)
            #expect(ReciprocalJointContactRules.contactTime(unrelated, at: row.contactMs) == nil)
            var confident = samples
            confident[index].landmarks[.rightAnkle]?.confidence = 0.9
            #expect(ReciprocalJointContactRules.contactTime(confident, at: row.contactMs) == nil)
        }
    }
}
