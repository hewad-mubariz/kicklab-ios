import XCTest
@testable import kicklab

final class SelectedPoseRecoveryTests: XCTestCase {
    private func views() -> [FootPoseSample] {
        zip([900,1000,1100],[0.26,0.35,0.27]).map { time,y in
            let points: [BodyJoint: PoseLandmark] = [
                .rightHip: .init(x: 0.3,y: 0.75,confidence: 0.8),
                .rightKnee: .init(x: 0.4,y: 0.4,confidence: 0.8),
                .rightAnkle: .init(x: 0.65,y: 0.42,confidence: 0.8)]
            return .init(pose: .init(timestampMs: time,ball: .init(x: 0.55,y: y),
                width: 0.1,height: 0.1,confidence: 0.9,imageAspect: 1,
                joints: points.mapValues { .init(x: $0.x,y: $0.y) }),ankles: [:],landmarks: points)
        }
    }
    private func replacing(_ sample: FootPoseSample,time: Int? = nil,ball: PosePoint? = nil,
                           aspect: Double = 1,landmarks: [BodyJoint: PoseLandmark]? = nil) -> FootPoseSample {
        let p = sample.pose, points = landmarks ?? sample.landmarks
        return .init(pose: .init(timestampMs: time ?? p.timestampMs,ball: ball ?? p.ball,width: p.width/aspect,
            height: p.height,confidence: p.confidence,imageAspect: aspect,joints: points.mapValues { .init(x: $0.x,y: $0.y) }),
            ankles: [:],landmarks: points)
    }
    func testRaisedShinReboundDoesNotRequireVisibleHands() {
        XCTAssertEqual(RaisedShinContactRules.contactTime(views(),at: 1000),1000)
    }
    func testNearbyConfidentWristBlocksRecovery() {
        let samples = views().map { sample in
            var points = sample.landmarks
            points[.leftWrist] = .init(x: sample.pose.ball.x,y: sample.pose.ball.y,confidence: 0.8)
            points[.leftElbow] = .init(x: 0.5,y: 0.4,confidence: 0.8)
            return replacing(sample,landmarks: points)
        }
        XCTAssertNil(RaisedShinContactRules.contactTime(samples,at: 1000))
    }
    func testLowLegCannotTurnAFloorBounceIntoAShinContact() {
        let samples = views().map { sample in
            var points = sample.landmarks
            points[.rightHip] = .init(x: 0.3,y: 0.2,confidence: 0.8)
            return replacing(sample,landmarks: points)
        }
        XCTAssertNil(RaisedShinContactRules.contactTime(samples,at: 1000))
    }
    func testStationaryBallAndSingleDirectionPassAreNotContacts() {
        let stationary = views().map { replacing($0,ball: .init(x: 0.55,y: 0.35)) }
        XCTAssertNil(RaisedShinContactRules.contactTime(stationary,at: 1000))
        var pass = views(); pass[2] = replacing(pass[2],ball: .init(x: 0.55,y: 0.39))
        XCTAssertNil(RaisedShinContactRules.contactTime(pass,at: 1000))
    }
    func testMissingImpactJointAndDiscontinuousPoseCannotRecover() {
        var samples = views(), points = samples[1].landmarks
        points.removeValue(forKey: .rightKnee)
        samples[1] = replacing(samples[1],landmarks: points)
        XCTAssertNil(RaisedShinContactRules.contactTime(samples,at: 1000))
        samples = views(); points = samples[0].landmarks
        points[.rightHip] = .init(x: 0.1,y: 0.75,confidence: 0.8)
        samples[0] = replacing(samples[0],landmarks: points)
        XCTAssertNil(RaisedShinContactRules.contactTime(samples,at: 1000))
    }
    func testStaleFramesAndInvalidBallCannotRecover() {
        var samples = views(); samples[0] = replacing(samples[0],time: 700)
        XCTAssertNil(RaisedShinContactRules.contactTime(samples,at: 1000))
        samples = views(); samples[1] = replacing(samples[1],ball: .init(x: .nan,y: 0.35))
        XCTAssertNil(RaisedShinContactRules.contactTime(samples,at: 1000))
    }
    func testMirroredAndLandscapeCoordinatesPreserveContact() {
        for mirrored in [false,true] {
            for aspect in [0.7,1.0,1.7778] {
                let samples = views().map { sample in
                    func x(_ x: Double) -> Double { let v = 0.5+(x-0.5)/aspect; return mirrored ? 1-v : v }
                    let points = sample.landmarks.mapValues { PoseLandmark(x: x($0.x),y: $0.y,confidence: $0.confidence) }
                    return replacing(sample,ball: .init(x: x(sample.pose.ball.x),y: sample.pose.ball.y),aspect: aspect,landmarks: points)
                }
                XCTAssertEqual(RaisedShinContactRules.contactTime(samples,at: 1000),1000)
            }
        }
    }
    func testRecoveryNeedsLockedObservedWidePlayerAndMatchingAnchors() {
        let baseline = BodyPose(joints: [.nose: .init(x: 0.2,y: 0.35),
            .leftShoulder: .init(x: 0.2,y: 0.5),.rightShoulder: .init(x: 0.22,y: 0.52)])
        let box = PersonBox(x: 0.45,y: 0.6,width: 0.6,height: 0.6)
        var player = ActivePlayerSelection(state: .locked,id: 1,box: box,observed: true,peopleCount: 5)
        XCTAssertEqual(SelectedPlayerPoseRecovery.direction(baseline: baseline,player: player,aspect: 1.7778),1)
        player = .init(state: .ambiguous,id: 1,box: box,observed: true,peopleCount: 5)
        XCTAssertNil(SelectedPlayerPoseRecovery.direction(baseline: baseline,player: player,aspect: 1.7778))
        player = .init(state: .locked,id: 1,box: box,observed: false,peopleCount: 5)
        XCTAssertNil(SelectedPlayerPoseRecovery.direction(baseline: baseline,player: player,aspect: 1.7778))
        XCTAssertNil(SelectedPlayerPoseRecovery.direction(baseline: baseline,player: nil,aspect: 1.7778))
        var other = baseline; other.joints = baseline.joints.mapValues { .init(x: $0.x+0.3,y: $0.y) }
        XCTAssertFalse(SelectedPlayerPoseRecovery.matches(other,baseline: baseline,box: box,aspect: 1.7778))
    }
    func testCropUsesObservedIdentityBeforeItsOverlappingPersonBoxes() {
        let box = PersonBox(x: 0.45,y: 0.6,width: 0.6,height: 0.6)
        let selected = BodyPose(joints: [.nose: .init(x: 0.2,y: 0.35),
            .leftShoulder: .init(x: 0.2,y: 0.5),.rightShoulder: .init(x: 0.22,y: 0.52),
            .leftHip: .init(x: 0.39,y: 0.71),.rightHip: .init(x: 0.39,y: 0.74)])
        let other = BodyPose(joints: [.nose: .init(x: 0.5,y: 0.32),
            .leftShoulder: .init(x: 0.48,y: 0.42),.rightShoulder: .init(x: 0.52,y: 0.42),
            .leftHip: .init(x: 0.48,y: 0.55),.rightHip: .init(x: 0.52,y: 0.55)])
        let player = ActivePlayerSelection(state: .locked,id: 1,box: box,observed: true,peopleCount: 5)
        XCTAssertNil(ActivePlayerPoseMatcher.index(in: [other,selected],selection: player))
        XCTAssertEqual(SelectedPlayerPoseRecovery.index(in: [other,selected],baseline: selected,player: player,aspect: 1.7778),1)
        XCTAssertNil(SelectedPlayerPoseRecovery.index(in: [other],baseline: selected,player: player,aspect: 1.7778))
        XCTAssertNil(SelectedPlayerPoseRecovery.index(in: [selected,selected],baseline: selected,player: player,aspect: 1.7778))
    }

}
