import XCTest
@testable import kicklab

final class GuardedBallFollowerTests: XCTestCase {
    let size=CGSize(width:1280,height:720)
    let initial=FollowHit(rect:CGRect(x:390,y:290,width:20,height:20),score:0.9)
    func seeded() throws -> GuardedBallFollower {
        let f=GuardedBallFollower()
        for i in 0..<3 { _=try f.step(time:Double(i)/120,size:size,flow:nil,sceneCut:false) { _ in [initial] } }
        return f
    }
    func cropped(_ hit: FollowHit, missing: Int? = nil) -> (FollowView) -> [FollowHit] {
        { view in view.width == 1280 || view.width == missing || !view.rect.contains(hit.rect) ? [] : [hit] }
    }
    func testThreeFrameTwoViewRecoveryDoesNotCommitPending() throws {
        let f=try seeded()
        for i in 0..<3 {
            let hit=FollowHit(rect:CGRect(x:470+i*3,y:300,width:20,height:20),score:0.8)
            let result=try f.step(time:0.2+Double(i)/120,size:size,flow:nil,sceneCut:false,infer:cropped(hit))
            if i<2 { XCTAssertNil(result.hit); XCTAssertEqual(f.last?.rect,initial.rect); XCTAssertEqual(f.verified,2.0/120) }
            else { XCTAssertEqual(result.hit?.rect,hit.rect); XCTAssertEqual(result.kind,"crop_reacquisition") }
        }
    }
    func testInsufficientEvidenceNeverCreatesRecovery() throws {
        for failure in ["one_view","weak","missed","jump"] {
            let f=try seeded()
            for i in 0..<3 {
                let x=failure == "jump" && i == 2 ? 520 : 470+i*3
                let hit=FollowHit(rect:CGRect(x:x,y:300,width:20,height:20),score:failure == "weak" ? 0.4 : 0.8)
                let predictor=cropped(hit,missing:failure == "one_view" ? 360 : nil)
                let r=try f.step(time:0.2+Double(i)/120,size:size,flow:nil,sceneCut:false) { view in
                    failure == "missed" && i == 1 ? [] : predictor(view)
                }
                XCTAssertNil(r.hit,failure)
            }
            XCTAssertEqual(f.last?.rect,initial.rect)
        }
    }
    func testSupportedFullFrameTakesPriorityOverTentativeCrop() throws {
        let f=try seeded()
        _=try f.step(time:0.2,size:size,flow:nil,sceneCut:false,infer:cropped(FollowHit(rect:CGRect(x:470,y:300,width:20,height:20),score:0.8)))
        let distant=FollowHit(rect:CGRect(x:800,y:300,width:20,height:20),score:0.85)
        for i in 0..<3 {
            let r=try f.step(time:0.21+Double(i)/120,size:size,flow:nil,sceneCut:false) { _ in [distant] }
            if i<2 { XCTAssertNil(r.hit) } else { XCTAssertEqual(r.hit?.rect,distant.rect); XCTAssertEqual(r.kind,"detector_reacquisition") }
        }
    }
    func testNoPredictionOnlyOutputAfterAgeLimitOrSceneCut() throws {
        let f=try seeded()
        XCTAssertNil(try f.step(time:0.2,size:size,flow:initial,sceneCut:false) { _ in [] }.hit)
        XCTAssertNil(try f.step(time:0.21,size:size,flow:initial,sceneCut:true) { _ in [] }.hit)
        XCTAssertNil(f.last)
    }
    func testInternalCropEdgeIsDistinctFromSourceBoundary() {
        let edge=FollowHit(rect:CGRect(x:0,y:0,width:20,height:20),score:0.9)
        XCTAssertFalse(GuardedBallFollower.edge(edge,FollowView(x:0,y:0,width:100,height:100),size))
        let clipped=FollowHit(rect:CGRect(x:90,y:40,width:10,height:10),score:0.9)
        XCTAssertTrue(GuardedBallFollower.edge(clipped,FollowView(x:0,y:0,width:100,height:100),size))
    }
    func testExplicitCandidateSelectionAndTimestampOrder() throws {
        XCTAssertEqual(BallDetector.resourceName(for:["--yolo26-motion-segmentation"]),"KickLabYOLO26MotionSegmentation")
        let f=try seeded()
        XCTAssertThrowsError(try f.step(time:2.0/120,size:size,flow:nil,sceneCut:false) { _ in [] })
    }
}
