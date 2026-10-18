import Foundation
import Testing
@testable import kicklab

struct ContactPoseContinuityTests {
    private final class Resources {}
    private struct Row: Decodable {
        struct View: Decodable {
            let timestampMs: Int
            let ball: [Double]
            let joints: [BodyJoint:[Double]]
            let ankles: [BodySide:[Double]]
            let landmarks: [BodyJoint:[Double]]
            var sample: FootPoseSample {
                .init(pose:.init(timestampMs:timestampMs,ball:.init(x:ball[0],y:ball[1]),
                    width:ball[2],height:ball[3],confidence:ball[4],imageAspect:ball[5],
                    joints:joints.mapValues { .init(x:$0[0],y:$0[1]) }),
                    ankles:ankles.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) },
                    landmarks:landmarks.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) })
            }
        }
        let frame, contactMs: Int
        let expected: Bool
        let samples: [View]
    }
    // Source F316B075-E2EF-4B12-81A3-42FD0964A8BD, SHA-256
    // 1d8d1cc18dae85ad74933852745ba735d79584b55382acab3f9ef10c5601426a.
    // Observed weak knee/ankle at 104.385s; wrist at 193.134s.
    // Complete pose loss at 183.766s stays unresolved, not invented.
    private func rows() throws -> [Row] {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"observed-joint-device-contacts",withExtension:"json"))
        return try JSONDecoder().decode([Row].self,from:Data(contentsOf:url))
    }
    private func eligible(_ samples: [FootPoseSample], _ time: Int) -> Bool {
        ClearHandsContactRules.failure(samples.map(\.pose),at:time) == nil
            || MovingFootContactRules.contactTime(samples,at:time) != nil
    }
    @Test func RecordedWeakLandmarksRecoverFootAndChestButNotAbsentPose() throws {
        for row in try rows() {
            let raw = row.samples.map(\.sample)
            #expect(!eligible(raw,row.contactMs))
            let corroborated = ContactPoseContinuity.corroborate(raw)
            #expect(eligible(corroborated,row.contactMs) == row.expected,"frame \(row.frame)")
            #expect(corroborated.map(\.ankles) == raw.map(\.ankles),"Never raise model confidence")
            #expect(corroborated.map(\.landmarks) == raw.map(\.landmarks),"Keep raw positions")
        }
    }
    @Test func MissingWeakWristOrUnreliableNeighbourCannotSupplyClearHands() throws {
        let row = try #require(rows().first { $0.frame == 4546 })
        for change in ["missing","weakNeighbour","contradiction"] {
            var raw = row.samples.map(\.sample)
            for index in raw.indices {
                let offset = raw[index].pose.timestampMs-row.contactMs
                if offset == 67 {
                    if change == "missing" { raw[index].landmarks[.rightWrist] = nil }
                    if change == "contradiction", let p = raw[index].landmarks[.rightWrist] {
                        raw[index].landmarks[.rightWrist] = .init(x:p.x-0.2,y:p.y,confidence:p.confidence)
                    }
                }
                if offset == 100, change == "weakNeighbour", var wrist = raw[index].landmarks[.rightWrist] {
                    wrist.confidence = 0.39; raw[index].landmarks[.rightWrist] = wrist
                }
            }
            #expect(!eligible(ContactPoseContinuity.corroborate(raw),row.contactMs),"\(change)")
        }
    }
    @Test func DuplicateFramesAndSideSwapsCannotEstablishContinuity() throws {
        let row = try #require(rows().first { $0.frame == 4546 })
        let raw = row.samples.map(\.sample)
        #expect(!eligible(ContactPoseContinuity.corroborate(raw+[raw[0]]),row.contactMs))
        let swapped = raw.map { s -> FootPoseSample in
            guard s.pose.timestampMs-row.contactMs == 100 else { return s }
            let p = s.pose
            var joints = p.joints
            joints[.rightShoulder] = joints[.leftShoulder]
            return .init(pose:.init(timestampMs:p.timestampMs,ball:p.ball,width:p.width,height:p.height,
                confidence:p.confidence,imageAspect:p.imageAspect,joints:joints),ankles:s.ankles,landmarks:s.landmarks)
        }
        #expect(!eligible(ContactPoseContinuity.corroborate(swapped),row.contactMs))
    }
}
