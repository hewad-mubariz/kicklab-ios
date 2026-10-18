import XCTest
@testable import kicklab

final class ActiveJugglerTrackerTests: XCTestCase {
    private let left = PersonBox(x: 0.3, y: 0.5, width: 0.25, height: 0.8)
    private let right = PersonBox(x: 0.8, y: 0.5, width: 0.2, height: 0.7)
    private func ball(_ x: Double, _ y: Double = 0.8, time: Int = 0) -> BallObservation {
        .init(frameIndex: 0, timestampMs: time, x: x, y: y, width: 0.05, height: 0.04, confidence: 0.95)
    }
    private func pose(at x: Double) -> BodyPose {
        var result = BodyPose()
        result.joints = [.nose: .init(x: x, y: 0.15), .leftShoulder: .init(x: x-0.05,y:0.3),
            .rightShoulder: .init(x: x+0.05,y:0.3), .leftHip: .init(x: x-0.04,y:0.55),
            .rightHip: .init(x: x+0.04,y:0.55)]
        return result
    }

    func testSinglePlayerStartsImmediatelyAndQueryOrderCannotStealLock() {
        var tracker = ActiveJugglerTracker()
        let start = tracker.update(people: [left], ball: ball(0.3), timestampMs: 0)
        XCTAssertEqual(start.state, .locked)
        for i in 1...20 {
            let people = i.isMultiple(of: 2) ? [left,right] : [right,left]
            let selected = tracker.update(people: people, ball: ball(0.8,0.2), timestampMs: i*50)
            XCTAssertEqual(selected.id, start.id)
            XCTAssertEqual(selected.box, left)
        }
    }

    func testSeveralPeopleRequireSustainedBallAssociation() {
        var tracker = ActiveJugglerTracker()
        for i in 0..<6 {
            XCTAssertNil(tracker.update(people: [right,left], ball: ball(0.3), timestampMs: i*50).id)
        }
        XCTAssertEqual(tracker.update(people: [left,right], ball: ball(0.3), timestampMs: 300).box, left)
    }

    func testInitialAmbiguityDoesNotSelectHighestConfidenceOrFirstPerson() {
        var tracker = ActiveJugglerTracker()
        let a = PersonBox(x: 0.43,y:0.5,width:0.4,height:0.8)
        let b = PersonBox(x: 0.57,y:0.5,width:0.4,height:0.8)
        for i in 0..<30 {
            let value = tracker.update(people:[a,b],ball:ball(0.5),timestampMs:i*50)
            XCTAssertNil(value.id)
            XCTAssertFalse(value.canMatchPose)
        }
    }

    func testCrossingAmbiguityDoesNotAssignTheBystanderPose() {
        var tracker = ActiveJugglerTracker()
        let first = tracker.update(people:[left,right],ball:ball(0.3),timestampMs:0)
        XCTAssertNil(first.id)
        var locked: ActivePlayerSelection?
        for i in 1...6 { locked = tracker.update(people:[left,right],ball:ball(0.3),timestampMs:i*50) }
        let overlap = PersonBox(x: 0.31,y:0.5,width:0.25,height:0.8)
        let result = tracker.update(people:[left,overlap],ball:ball(0.3),timestampMs:350)
        XCTAssertEqual(result.id, locked?.id)
        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertFalse(result.canMatchPose)
    }

    func testBriefDetectorLossKeepsIdentityButRequiresObservedPose() {
        var tracker = ActiveJugglerTracker()
        let first = tracker.update(people:[left],ball:ball(0.3),timestampMs:0)
        let missing = tracker.update(people:[],ball:ball(0.3),timestampMs:300)
        XCTAssertEqual(missing.id, first.id)
        XCTAssertEqual(missing.state, .obscured)
        XCTAssertFalse(missing.observed)
        XCTAssertNil(ActivePlayerPoseMatcher.index(in: [],selection: missing))
        XCTAssertEqual(ActivePlayerPoseMatcher.index(in:[pose(at:0.8),pose(at:0.3)],selection:missing),1)
        let stale = tracker.update(people:[],ball:ball(0.3),timestampMs:600)
        XCTAssertFalse(stale.canMatchPose)
        let recovered = tracker.update(people:[left],ball:ball(0.3),timestampMs:700)
        XCTAssertEqual(recovered.id,first.id)
    }

    func testExpiredPlayerAndClockDiscontinuityGetNewIdentity() {
        var tracker = ActiveJugglerTracker()
        let first = tracker.update(people:[left],ball:ball(0.3),timestampMs:0)
        _ = tracker.update(people:[],ball:nil,timestampMs:500)
        _ = tracker.update(people:[],ball:nil,timestampMs:1000)
        let next = tracker.update(people:[right],ball:ball(0.8),timestampMs:1300)
        XCTAssertNotEqual(next.id,first.id)
        let restarted = tracker.update(people:[right],ball:ball(0.8),timestampMs:100)
        XCTAssertNotEqual(restarted.id,next.id)
    }

    func testLowCadenceUsesElapsedTimeAndDoesNotRequireThirtyFrames() {
        var tracker = ActiveJugglerTracker()
        for time in [0,100,200] { XCTAssertNil(tracker.update(people:[left,right],ball:ball(0.3),timestampMs:time).id) }
        XCTAssertNotNil(tracker.update(people:[left,right],ball:ball(0.3),timestampMs:300).id)
    }

    func testSingleUnrelatedPoseCannotSubstituteForSelectedPlayer() {
        let selection = ActivePlayerSelection(state:.locked,id:1,box:left,observed:true,peopleCount:2)
        XCTAssertNil(ActivePlayerPoseMatcher.index(in:[pose(at:0.8)],selection:selection))
        XCTAssertEqual(ActivePlayerPoseMatcher.index(in:[pose(at:0.8),pose(at:0.3)],selection:selection),1)
        XCTAssertNil(ActivePlayerPoseMatcher.index(in:[pose(at:0.3),pose(at:0.31)],selection:selection))
    }

    func testSelectingPartialPoseDoesNotInventMissingLegs() throws {
        let poses = [pose(at:0.3),pose(at:0.8)]
        let selection = ActivePlayerSelection(state:.locked,id:1,box:left,observed:true,peopleCount:2)
        let index = try XCTUnwrap(ActivePlayerPoseMatcher.index(in:poses,selection:selection))
        XCTAssertNil(poses[index].joints[.leftKnee])
        XCTAssertNil(poses[index].joints[.rightAnkle])
    }

    func testHistoricalTracesKeepSinglePoseSemanticsAndNewSelectionRoundTrips() throws {
        XCTAssertEqual(ActivePlayerPoseMatcher.index(in:[pose(at:0.3)],selection:nil),0)
        XCTAssertNil(ActivePlayerPoseMatcher.index(in:[pose(at:0.3),pose(at:0.8)],selection:nil))
        let input = CounterTrace.Input(frameIndex:0,timestampMs:0,sourceFrameIndex:0,ball:nil,person:left,
            cameraOffsetY:0,reliable:true,player:.init(state:.locked,id:3,box:left,observed:true,peopleCount:2))
        let data = try JSONEncoder().encode(input)
        XCTAssertEqual(try JSONDecoder().decode(CounterTrace.Input.self,from:data).player,input.player)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        object.removeValue(forKey:"player")
        XCTAssertNil(try JSONDecoder().decode(CounterTrace.Input.self,from:JSONSerialization.data(withJSONObject:object)).player)
    }

    func testRecordedGuinnessPosesSelectTheSeatedPlayerWithoutBorrowingSpectatorLegs() throws {
        struct Row: Decodable {
            let frame: Int
            let box: PersonBox
            let poses: [[BodyJoint: PosePoint]]
            let expected: Int
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "active-player-guinness-poses", withExtension: "json"))
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let poses = row.poses.map { BodyPose(joints: $0) }
            let selection = ActivePlayerSelection(state: .locked, id: 1, box: row.box, observed: true, peopleCount: poses.count)
            let selected = try XCTUnwrap(ActivePlayerPoseMatcher.index(in: poses, selection: selection))
            XCTAssertEqual(selected, row.expected, "Frame \(row.frame)")
            XCTAssertNil(poses[selected].joints[.leftKnee])
            XCTAssertNil(poses[selected].joints[.rightKnee])
            XCTAssertNil(poses[selected].joints[.leftAnkle])
            XCTAssertNil(poses[selected].joints[.rightAnkle])
        }
    }

    func testTrackStorageRemainsBoundedAndRejectsInvalidBoxes() {
        var tracker = ActiveJugglerTracker()
        let bad = PersonBox(x:.nan,y:0,width:0,height:0)
        let many = (0..<100).map { PersonBox(x: Double($0)/100,y:0.5,width:0.02,height:0.2) }
        for i in 0..<100 {
            _ = tracker.update(people: [bad]+many,ball:nil,timestampMs:i*33)
            XCTAssertLessThanOrEqual(tracker.players.count,8)
        }
    }
}
