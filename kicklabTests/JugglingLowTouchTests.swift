import Foundation
import Testing
@testable import kicklab

struct JugglingLowTouchTests {
    // Real center/size observations from source 48ff...3 2.mov, frames 0–35.
    // SHA256 6e250e0976e4c584adef498bbe43cb5d7705ef374f1c7437f0cfe0d53f331e81.
    // Reviewed foot contacts at frames 10, 20, 28; the old fixed fall gate kept
    // only frame 20. Body position is held safely above the ground in this fixture
    // to isolate the measured trajectory; full-video replays retain actual boxes.
    private let observations: [(ms: Int, y: Double, height: Double)] = [
        (0, 0.526171863079, 0.062500000000),
        (66, 0.535546898842, 0.062500000000),
        (99, 0.546289086342, 0.066796839237),
        (133, 0.541015625000, 0.068750023842),
        (166, 0.530468761921, 0.064843773842),
        (199, 0.525390625000, 0.064062476158),
        (233, 0.523437500000, 0.064843773842),
        (266, 0.523828148842, 0.064843714237),
        (299, 0.527343750000, 0.065624982119),
        (333, 0.533593773842, 0.066406250000),
        (366, 0.544531226158, 0.069531261921),
        (399, 0.541406273842, 0.071093738079),
        (433, 0.531250000000, 0.068750023842),
        (466, 0.524609386921, 0.065624982119),
        (499, 0.520703136921, 0.065624982119),
        (533, 0.520898461342, 0.066015630960),
        (566, 0.523046851158, 0.064843744040),
        (599, 0.528515636921, 0.065624982119),
        (633, 0.537500023842, 0.065625011921),
        (666, 0.549609422684, 0.067187488079),
        (699, 0.555859386921, 0.068750023842),
        (732, 0.546093761921, 0.067968726158),
        (766, 0.536328136921, 0.066406250000),
        (799, 0.530468761921, 0.066406250000),
        (832, 0.528906226158, 0.066406220198),
        (866, 0.528710961342, 0.066796839237),
        (899, 0.532031238079, 0.067968726158),
        (932, 0.539843797684, 0.067187488079),
        (966, 0.548828125000, 0.068750023842),
        (999, 0.551562547684, 0.074999988079),
        (1032, 0.537500023842, 0.069531261921),
        (1066, 0.527343750000, 0.068750023842),
        (1099, 0.519531250000, 0.067968726158),
        (1132, 0.516406238079, 0.067968726158),
        (1166, 0.516406297684, 0.069531261921),
        (1199, 0.517968773842, 0.068749964237),
    ]

    private func replay(scale: Double = 1, shift: Double = 0,
                        height: ((Int, Double) -> Double)? = nil,
                        rejectsHand: ((Int) -> Bool)? = nil) -> StreamingCounter {
        let counter = StreamingCounter(rejectsHandContact: rejectsHand)
        let person = PersonBox(x: 0.5, y: 0.45, width: 0.8, height: 0.9)
        for (i, row) in observations.enumerated() {
            let y = 0.5 + (row.y - 0.5) * scale + shift
            counter.push(frameIndex: i, timestampMs: row.ms,
                ball: BallObservation(frameIndex: i, timestampMs: row.ms, x: 0.5, y: y,
                    width: row.height * scale, height: height?(i, row.height) ?? row.height * scale,
                    confidence: 0.9), person: person)
        }
        counter.flush()
        return counter
    }

    @Test(arguments: [0.85, 1.0, 1.5])
    func recoversReviewedLowKeepUpsAcrossFraming(scale: Double) {
        let counter = replay(scale: scale)
        #expect(counter.touches.map(\.frameIndex) == [10, 20, 28])
        #expect(counter.flush().isEmpty)
    }

    @Test func oneBadSizeDoesNotEraseARealSoftTouch() {
        let counter = replay(height: { i, h in i == 10 ? 0.8 : h })
        #expect(counter.touches.map(\.frameIndex) == [10, 20, 28])
    }

    @Test(arguments: [0.0, -0.1, Double.nan, Double.infinity])
    func invalidSizesKeepConservativeFallback(invalid: Double) {
        #expect(replay(height: { _, _ in invalid }).touches.map(\.frameIndex) == [20])
    }

    @Test func sparseSizesDoNotRelaxTheGate() {
        #expect(replay(height: { i, h in i == 10 ? h : 0 }).touches.map(\.frameIndex) == [20])
    }

    @Test func closeLargeBallRetainsTheStricterMovementRequirement() {
        #expect(replay(height: { _, _ in 0.25 }).touches.map(\.frameIndex) == [20])
    }

    @Test func newlyEligibleSmallReversalsStillRespectGroundAndHandVeto() {
        #expect(replay(shift: 0.36).count == 0)
        #expect(replay(rejectsHand: { $0 == 10 }).touches.map(\.frameIndex) == [20, 28])
    }

    @Test func stationaryBallJitterDoesNotAccumulateTouches() {
        let counter = StreamingCounter()
        for i in 0..<180 {
            counter.push(frameIndex: i, timestampMs: i * 33,
                ball: BallObservation(frameIndex: i, timestampMs: i * 33, x: 0.5,
                    y: 0.6 + 0.003 * sin(Double(i) * .pi / 4),
                    width: 0.02, height: 0.01, confidence: 0.9),
                person: PersonBox(x: 0.5, y: 0.45, width: 0.8, height: 0.9))
        }
        counter.flush()
        #expect(counter.count == 0)
    }
}
