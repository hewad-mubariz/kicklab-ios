import CoreGraphics
import Testing
@testable import kicklab

struct RFMotionRecoveryTests {
    private func hit(_ x: Double, _ y: Double, _ width: Double = 100,
                     _ height: Double = 100, score: Double = 0.95) -> FollowHit {
        FollowHit(rect: CGRect(x: x-width/2, y: y-height/2, width: width, height: height), score: score)
    }
    private func normalized(_ rect: [Double], score: Double = 0.95) -> FollowHit {
        FollowHit(rect: CGRect(x: rect[0]*720, y: rect[1]*1280,
                              width: rect[2]*720, height: rect[3]*1280), score: score)
    }
    private func candidate(_ hit: FollowHit, query: Int = 0) -> AsyncBallCandidate {
        AsyncBallCandidate(query: query, hit: hit)
    }

    @Test func measuredHighKickCanReacquireBeyondTheOldPositionGate() {
        // Actual iPhone replay: last two tracked exposures and returning RF box.
        let a = normalized([0.49567815992567277, 0.37379522323608394, 0.1402587890625, 0.08551025390625])
        let b = normalized([0.49417665269639754, 0.3535554468631745, 0.14409875869750977, 0.08785132765769958])
        let returning = candidate(hit(0.616*720, 0.044*1280, 0.156*720, 0.083*1280, score: 0.968))
        var recovery = RFMotionRecovery()
        recovery.observe(a, at: 11.555); recovery.observe(b, at: 11.588333333)
        #expect(RFAsyncPolicy().select([returning], hint: b).0 == nil)
        #expect(recovery.select([returning], at: 11.821666667)?.query == 0)
    }

    @Test func measuredFastDescentReacquiresAtTheFoot() {
        let a = normalized([0.55938720703125, 0.041900634765625, 0.1370849609375, 0.09686279296875])
        let b = normalized([0.561614990234375, 0.178619384765625, 0.12091064453125, 0.08538818359375])
        let returning = candidate(hit(0.595*720, 0.486*1280, 0.107*720, 0.066*1280, score: 0.960))
        var recovery = RFMotionRecovery()
        recovery.observe(a, at: 12.421666667); recovery.observe(b, at: 12.521666667)
        #expect(RFAsyncPolicy().select([returning], hint: b).0 == nil)
        #expect(recovery.select([returning], at: 12.721666667)?.query == 0)
    }

    @Test func stationaryOrOppositeAndSidewaysBallsCannotUseRecovery() {
        var recovery = RFMotionRecovery()
        recovery.observe(hit(300, 500), at: 1)
        recovery.observe(hit(300, 400), at: 1.05)
        let spare = candidate(hit(300, 500))
        let sideways = candidate(hit(600, 100))
        #expect(recovery.select([spare, sideways], at: 1.2) == nil)
        var stationary = RFMotionRecovery()
        stationary.observe(hit(300, 500), at: 1)
        stationary.observe(hit(300, 500), at: 1.05)
        #expect(stationary.select([candidate(hit(300, 100))], at: 1.2) == nil)
    }

    @Test func ambiguityWeakScoresAndScaleChangesWaitForEvidence() {
        var recovery = RFMotionRecovery()
        recovery.observe(hit(300, 500), at: 1)
        recovery.observe(hit(300, 400), at: 1.05)
        let real = candidate(hit(300, 100))
        #expect(recovery.select([real], at: 1.2) != nil)
        #expect(recovery.select([real, candidate(hit(320, 90), query: 1)], at: 1.2) == nil)
        #expect(recovery.select([candidate(hit(300, 100, score: 0.69))], at: 1.2) == nil)
        #expect(recovery.select([candidate(hit(300, 100, 180, 180))], at: 1.2) == nil)
        #expect(recovery.select([candidate(hit(300, 100, 50, 50))], at: 1.2) == nil)
    }

    @Test func staleSparseOrOutOfOrderHistoryCannotInventMotion() {
        var recovery = RFMotionRecovery()
        recovery.observe(hit(300, 500), at: 1)
        recovery.observe(hit(300, 400), at: 1.05)
        recovery.observe(hit(800, 800), at: 1.01)
        #expect(recovery.select([candidate(hit(300, 100))], at: 1.2) != nil)
        #expect(recovery.select([candidate(hit(300, 100))], at: 1.4) == nil)
        #expect(recovery.select([candidate(hit(300, 100))], at: .nan) == nil)
        var sparse = RFMotionRecovery()
        sparse.observe(hit(300, 500), at: 1)
        sparse.observe(hit(300, 400), at: 2)
        #expect(sparse.select([candidate(hit(300, 100))], at: 2.1) == nil)
    }
}
