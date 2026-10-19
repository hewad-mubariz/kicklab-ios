#if DEBUG
import XCTest
import CoreGraphics
@testable import kicklab

final class WallRuntimeTests: XCTestCase {
    func testReferenceCapHandlesSensorJitterAndNeverCapsGameplay() {
        var cadence = WallInferenceCadence()
        let admitted = (0..<600).filter { frame in
            let jitter = frame.isMultiple(of: 2) ? 0.0001 : -0.0001
            return cadence.admit(at: Double(frame) / 60 + jitter,
                scoring: false, collectingReference: true, referenceFinished: false)
        }
        XCTAssertEqual(admitted.count, 150)
        XCTAssertEqual(admitted.first, 0)
        // Immediately entering play admits every available timestamp, even
        // within the prior reference interval and through marker occlusion.
        for frame in 0..<60 {
            XCTAssertTrue(cadence.admit(at: 10 + Double(frame) / 120,
                scoring: true, collectingReference: false, referenceFinished: false))
        }
        XCTAssertFalse(cadence.admit(at: 11, scoring: false, collectingReference: false, referenceFinished: false))
        XCTAssertTrue(cadence.admit(at: 11.001, scoring: false, collectingReference: true, referenceFinished: false))
        XCTAssertFalse(cadence.admit(at: 11.002, scoring: false, collectingReference: true, referenceFinished: true))
        cadence.reset()
        XCTAssertTrue(cadence.admit(at: 11.003, scoring: false, collectingReference: true, referenceFinished: false))
    }

    func testFifteenFPSKeepsThreeSecondReferenceAndRejectsWrongTarget() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 900, y: 0),
                              bottomRight: CGPoint(x: 900, y: 600), bottomLeft: CGPoint(x: 0, y: 600))!
        var correct = WallReferenceCollector(board: board, target: 1, imageWidth: 900)
        var wrong = WallReferenceCollector(board: board, target: 1, imageWidth: 900)
        var cadence = WallInferenceCadence()
        var completedAt: Double?
        for frame in 0..<210 {
            let t = Double(frame) / 60
            guard cadence.admit(at: t, scoring: false, collectingReference: true, referenceFinished: false) else { continue }
            let result = correct.add(.init(t: t, x: 150, y: 150, d: 60, score: 0.8, aspect: 1), now: t)
            if let diameter = result.diameter {
                if completedAt == nil { completedAt = t }
                XCTAssertEqual(diameter, 60.0 / 900, accuracy: 0.000001)
            }
            XCTAssertNil(wrong.add(.init(t: t, x: 450, y: 150, d: 60, score: 0.8, aspect: 1), now: t).diameter)
        }
        XCTAssertNotNil(completedAt)
        XCTAssertGreaterThanOrEqual(completedAt ?? 0, 3)
        XCTAssertLessThanOrEqual(completedAt ?? 99, 3.1)
    }

    func testWorkReportDrainsItsIntervalAndKeepsSeparateStageCalls() {
        var meter = WallWorkMeter(at: 10)
        meter.note(.boardModel, milliseconds: 18)
        meter.note(.boardModel, milliseconds: 20)
        meter.note(.fullFrameModel, milliseconds: 17)
        meter.skippedReferenceFrame()
        let sample = meter.take(at: 11)
        XCTAssertEqual(sample.windowSeconds, 1)
        XCTAssertEqual(sample.stages["boardModel"]?.calls, 2)
        XCTAssertEqual(sample.stages["boardModel"]?.totalMS, 38)
        XCTAssertEqual(sample.stages["boardModel"]?.maximumMS, 20)
        XCTAssertEqual(sample.stages["fullFrameModel"]?.calls, 1)
        XCTAssertEqual(sample.referenceFramesSkipped, 1)
        let idle = meter.take(at: 12)
        XCTAssertTrue(idle.stages.isEmpty)
        XCTAssertEqual(idle.referenceFramesSkipped, 0)
    }

    func testOnlyLiveScoringOrUnfinishedBallReferenceNeedsInference() {
        for scoring in [false, true] {
            for reference in [false, true] {
                for finished in [false, true] {
                    let expected = scoring || reference && !finished
                    XCTAssertEqual(WallRuntimePolicy.needsInference(scoring: scoring,
                        collectingReference: reference, referenceFinished: finished), expected)
                }
            }
        }
        // Missing corners are a live scoring pause, not an idle game: keep
        // collecting evidence so brief occlusion recovery still works.
        XCTAssertTrue(WallRuntimePolicy.needsInference(scoring: true,
            collectingReference: false, referenceFinished: true))
    }

    func testHotPhoneCannotBeginAnotherRoundAndCriticalEndsCurrentRound() {
        for state in [-1, 0, 1, 2, 3] {
            let sample = WallRuntimeSample(thermalState: state)
            XCTAssertEqual(sample.canStartRound, state == 0 || state == 1)
            XCTAssertEqual(sample.allowsMacPreview, state == 0 || state == 1)
            XCTAssertEqual(sample.shouldEndRound, state == 3)
        }
        XCTAssertEqual(WallRuntimeSample(thermalState: 2).thermalLabel, "Serious")
        XCTAssertEqual(WallRuntimeSample(thermalState: 3).thermalLabel, "Critical")
    }

    func testUnavailableMemoryIsNotReportedAsZeroUsage() throws {
        let sample = WallRuntimeSample(uptime: 100, thermalState: 0)
        let decoded = try JSONDecoder().decode(WallRuntimeSample.self, from: JSONEncoder().encode(sample))
        XCTAssertNil(decoded.memoryMiB)
        XCTAssertNil(decoded.peakMemoryMiB)
        XCTAssertEqual(sample, decoded)
    }
}
#endif
