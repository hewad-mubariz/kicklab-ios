import XCTest
@testable import kicklab

final class ToePlayerAssociationTests: XCTestCase {
    let box = PersonBox(x: 0.54, y: 0.59, width: 0.34, height: 0.51)
    func selection(people: Int = 1, id: Int = 1, state: ActivePlayerSelection.State = .locked,
                   observed: Bool = true) -> ActivePlayerSelection {
        .init(state: state, id: id, box: box, observed: observed, peopleCount: people)
    }
    func pose(x: Double = 0.54, scale: Double = 1, confidence: Double = 0.95) -> BodyPose {
        let values: [(BodyJoint, Double, Double)] = [(.nose,0,-0.17),(.leftShoulder,-0.09,-0.12),
            (.rightShoulder,0.09,-0.12),(.leftHip,-0.06,0.02),(.rightHip,0.06,0.02)]
        var result = BodyPose()
        for (joint, dx, dy) in values {
            result.joints[joint] = .init(x: x+dx*scale, y: 0.59+dy*scale)
            result.landmarks[joint] = .init(x: x+dx*scale, y: 0.59+dy*scale, confidence: confidence)
        }
        return result
    }
    func testBackgroundPersonDoesNotDisableStablePlayerWindow() {
        // The user's 36.631 s contact has this exact 2,1,1 visibility pattern.
        XCTAssertTrue(ToePlayerAssociation.sameObservedPlayer([selection(people:2),selection(),selection()]))
    }
    func testIdentitySwitchAmbiguityAndUnobservedPlayerRejectWindow() {
        XCTAssertFalse(ToePlayerAssociation.sameObservedPlayer([selection(),selection(id:2),selection()]))
        XCTAssertFalse(ToePlayerAssociation.sameObservedPlayer([selection(),selection(state:.ambiguous),selection()]))
        XCTAssertFalse(ToePlayerAssociation.sameObservedPlayer([selection(),selection(observed:false),selection()]))
        XCTAssertFalse(ToePlayerAssociation.sameObservedPlayer([nil,selection(),selection()]))
        XCTAssertFalse(ToePlayerAssociation.sameObservedPlayer([selection(),selection()]))
    }
    func testPoseOrderCannotChooseTheSpectator() {
        let player = pose(), spectator = pose(x:0.24,scale:0.15), s = selection(people:2)
        XCTAssertEqual(ToePlayerAssociation.index(in:[spectator,player],selection:s),1)
        XCTAssertEqual(ToePlayerAssociation.index(in:[player,spectator],selection:s),0)
        XCTAssertNil(ToePlayerAssociation.index(in:[spectator],selection:s))
    }
    func testSmallSpectatorInsideBoxCannotSupplyFeet() {
        XCTAssertNil(ToePlayerAssociation.index(in:[pose(scale:0.15)],selection:selection(people:2)))
    }
    func testOverlappingPosesAndWeakTorsoAreRejected() {
        XCTAssertNil(ToePlayerAssociation.index(in:[pose(),pose(x:0.55)],selection:selection(people:2)))
        XCTAssertNil(ToePlayerAssociation.index(in:[pose(confidence:0.4)],selection:selection(people:2)))
    }
    func testNoPoseAndMissingTorsoCannotBeInvented() {
        XCTAssertNil(ToePlayerAssociation.index(in:[],selection:selection(people:2)))
        var partial = pose(); partial.landmarks.removeValue(forKey:.rightHip)
        XCTAssertNil(ToePlayerAssociation.index(in:[partial],selection:selection(people:2)))
    }
}
