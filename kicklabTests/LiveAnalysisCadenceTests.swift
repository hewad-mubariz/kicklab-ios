import Foundation
import XCTest
@testable import kicklab

final class LiveAnalysisCadenceTests: XCTestCase {
    func testEmptySceneWaitsTwoSecondsAndEitherDetectionImmediatelyRestoresCadence() {
        for playerReturns in [true, false] {
            var policy = LiveAnalysisCadence()
            for i in 0..<60 {
                policy.observe(time: Double(i) / 30, hasBall: false, hasPerson: false, thermal: .nominal)
                XCTAssertEqual(policy.framesPerSecond, 30)
            }
            policy.observe(time: 2, hasBall: false, hasPerson: false, thermal: .nominal)
            XCTAssertEqual(policy.framesPerSecond, 5)
            policy.observe(time: 2.2, hasBall: !playerReturns, hasPerson: playerReturns, thermal: .nominal)
            XCTAssertEqual(policy.framesPerSecond, 30)
            for i in 0..<600 {
                policy.observe(time: 3 + Double(i) / 30, hasBall: !playerReturns, hasPerson: playerReturns, thermal: .nominal)
                XCTAssertFalse(policy.isIdle, "Ball occlusion or a missing person box must not slow an active scene")
            }
        }
    }

    func testThermalReductionIsImmediateAndRecoveryRequiresStableCoolerState() {
        var policy = LiveAnalysisCadence()
        func update(_ time: Double, _ thermal: ProcessInfo.ThermalState) {
            policy.observe(time: time, hasBall: true, hasPerson: true, thermal: thermal)
        }
        update(0, .fair); XCTAssertEqual(policy.framesPerSecond, 20)
        update(1, .serious); XCTAssertEqual(policy.framesPerSecond, 15)
        update(2, .nominal); update(11, .nominal); XCTAssertEqual(policy.framesPerSecond, 15)
        update(11.5, .serious) // Reheating resets the recovery clock.
        update(12, .fair); update(21.9, .fair); XCTAssertEqual(policy.framesPerSecond, 15)
        update(22, .fair); XCTAssertEqual(policy.framesPerSecond, 20)
        update(23, .critical); XCTAssertEqual(policy.framesPerSecond, 10)
        update(24, .nominal); update(34, .nominal); XCTAssertEqual(policy.framesPerSecond, 30)
    }

    func testDynamicSchedulingPreservesSourceClockAndOnePendingFrame() {
        var buffer = LiveAnalysisBuffer<Int>()
        for fps in [30.0, 20, 15, 5, 30] {
            buffer = LiveAnalysisBuffer<Int>()
            buffer.setFramesPerSecond(fps)
            var selected: [Int] = []
            for i in 0..<600 {
                if let frame = buffer.offer(i, at: 10_000 + Double(i) / 59.94) {
                    selected.append(frame)
                    XCTAssertNil(buffer.finish())
                }
            }
            XCTAssertEqual(selected.count, Int(fps * 10))
            XCTAssertEqual(selected[1] - selected[0], Int(60 / fps))
        }
        XCTAssertEqual(buffer.offer(600, at: 10_020), 600)
        buffer.setFramesPerSecond(5)
        XCTAssertNil(buffer.offer(601, at: 10_020.1))
        XCTAssertNil(buffer.offer(602, at: 10_020.2))
        XCTAssertNil(buffer.offer(603, at: 10_020.4))
        XCTAssertEqual(buffer.finish(), 603)
        buffer.setFramesPerSecond(30)
        XCTAssertNil(buffer.offer(604, at: 10_020.44))
        XCTAssertEqual(buffer.finish(), 604)
        XCTAssertNil(buffer.finish())
    }
}
