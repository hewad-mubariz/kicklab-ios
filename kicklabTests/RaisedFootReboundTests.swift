import XCTest
@testable import kicklab

final class RaisedFootReboundTests: XCTestCase {
    private struct Row: Decodable {
        struct View: Decodable {
            var timestampMs: Int
            var ball: [Double]
            var landmarks: [BodyJoint:[Double]]
            var sample: FootPoseSample {
                let points = landmarks.mapValues { PoseLandmark(x:$0[0],y:$0[1],confidence:$0[2]) }
                return .init(pose:.init(timestampMs:timestampMs,ball:.init(x:ball[0],y:ball[1]),
                    width:ball[2],height:ball[3],confidence:ball[4],imageAspect:ball[5],
                    joints:points.filter { $0.value.confidence >= 0.3 }.mapValues { .init(x:$0.x,y:$0.y) }),
                    ankles:[:],landmarks:points)
            }
        }
        let id: String
        let contactMs: Int
        let expected: Bool
        var samples: [View]
    }
    private func rows() throws -> [Row] {
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"raised-foot-rebound-device-contacts",withExtension:"json"))
        return try JSONDecoder().decode([Row].self,from:Data(contentsOf:url))
    }
    private func recovered(_ row: Row) -> Int? { ObservedLegContactRules.contactTime(row.samples.map(\.sample),at:row.contactMs,usesTemporalEvidence:true,usesCadenceWindow:true,allowsNearSupportFoot:true)
            ?? RaisedFootReboundRules.contactTime(row.samples.map(\.sample),at:row.contactMs) }
    func testReviewedRaisedFeetAndHandVetoControls() throws {
        for row in try rows() { XCTAssertEqual(recovered(row) != nil,row.expected,row.id) }
    }
    func testMissingWeakStationaryOrStaleLegsCannotRecover() throws {
        for original in try rows() where original.expected {
            for change in ["missing","weak","stationary","noRelease","stale","floor","contradictory"] {
                var row = original
                let first = try XCTUnwrap(row.samples.first)
                row.samples = row.samples.map { view in
                    var s = view
                    switch change {
                    case "missing": s.landmarks = [:]
                    case "weak": s.landmarks = s.landmarks.mapValues { [$0[0],$0[1],0.29] }
                    case "stationary": s.landmarks = first.landmarks
                    case "stale": s.timestampMs = row.contactMs+(s.timestampMs-row.contactMs)*3
                    case "floor": s.ball[1] = 0.98
                    case "contradictory":
                        if (0...101).contains(s.timestampMs-row.contactMs) {
                            s.landmarks[.leftAnkle] = [0.05,0.98,0.95]
                            s.landmarks[.rightAnkle] = [0.95,0.98,0.95]
                        }
                    default: break
                    }
                    return s
                }
                if change == "noRelease" { row.samples.removeAll { $0.timestampMs > row.contactMs } }
                XCTAssertNil(recovered(row),"\(row.id), \(change)")
            }
        }
    }
    func testMirroredLegsKeepTheSameContactTime() throws {
        for original in try rows() where original.expected {
            var row = original
            row.samples = row.samples.map { view in
                var s = view; s.ball[0] = 1-s.ball[0]
                s.landmarks = Dictionary(uniqueKeysWithValues:s.landmarks.map { joint,values in
                    let key = BodyJoint(rawValue:joint.rawValue.replacingOccurrences(of:"left_",with:"swap_")
                        .replacingOccurrences(of:"right_",with:"left_").replacingOccurrences(of:"swap_",with:"right_"))!
                    return (key,[1-values[0],values[1],values[2]])
                })
                return s
            }
            XCTAssertEqual(recovered(row),recovered(original),row.id)
        }
    }
}
