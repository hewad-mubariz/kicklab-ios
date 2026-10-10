import XCTest
@testable import kicklab

@MainActor
final class BallDetectionConfirmationTests: XCTestCase {
    private let strong = [0.8,0.5,0.5,0.04,0.0225]
    private let weak = [0.32,0.5,0.5,0.04,0.0225]
    private func request(_ policy: BallDetectionConfirmation, _ time: Double?, _ ball: [Double]) -> BallDetectionConfirmation.Request? {
        policy.observe(time:time,width:720,height:1280,direct:ball)
    }
    func testWeakObjectsNeedPixelsAndCropsNeverSeedHistory() throws {
        let policy=BallDetectionConfirmation()
        let first=try XCTUnwrap(request(policy,0,weak))
        XCTAssertFalse(BallDetectionConfirmation.accepts(first,crop:[0,0,0,0,0],maskFill:0))
        let crop=[0.8,(weak[1]*720-Double(first.roi[0]))/Double(first.roi[2]),
            (weak[2]*1280-Double(first.roi[1]))/Double(first.roi[3]),
            weak[3]*720/Double(first.roi[2]),weak[4]*1280/Double(first.roi[3])]
        XCTAssertTrue(BallDetectionConfirmation.accepts(first,crop:crop,maskFill:0.7))
        XCTAssertFalse(BallDetectionConfirmation.accepts(first,crop:crop,maskFill:0.99))
        XCTAssertNotNil(request(policy,1/120,weak))
    }
    func testRecentStrongAnchorExpiresAndCannotProtectDifferentObject() {
        let policy=BallDetectionConfirmation()
        XCTAssertNil(request(policy,0,strong))
        XCTAssertNil(request(policy,0.10,weak))
        XCTAssertNotNil(request(policy,0.151,weak))
        _=request(policy,1,strong)
        XCTAssertNotNil(request(policy,1.01,[0.32,0.9,0.1,0.04,0.0225]))
    }
    func testSeekSceneAndDimensionChangesDropHistory() {
        let times: [Double?] = [0,-1,nil,.nan]
        for time in times {
            let policy=BallDetectionConfirmation()
            _=request(policy,0,strong)
            XCTAssertNotNil(request(policy,time,weak))
        }
        let policy=BallDetectionConfirmation()
        _=request(policy,0,strong);policy.reset()
        XCTAssertNotNil(request(policy,0.01,weak))
        _=request(policy,1,strong)
        XCTAssertNotNil(policy.observe(time:1.01,width:1280,height:720,direct:weak))
    }
}
