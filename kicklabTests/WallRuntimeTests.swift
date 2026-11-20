#if DEBUG
import XCTest
import CoreGraphics
@testable import kicklab

final class WallRuntimeTests: XCTestCase {
    func testRecordingSamplesIdleVideoAtTenFPSWithoutChangingCaptureTimestamps() {
        var cadence = WallRecordingCadence()
        var kept: [Double] = []
        for i in 0..<600 {
            let t = 100 + Double(i) / 60
            if cadence.shouldRecord(at: t, inferenceRan: false, hasBall: false, source: 0) {
                cadence.recorded(at: t); kept.append(t)
            }
        }
        XCTAssertEqual(kept.count, 100)
        XCTAssertEqual(kept.first, 100)
        XCTAssertEqual(kept.last ?? 0, 109.9, accuracy: 0.00001)
    }

    func testRecordingNeverIntentionallySkipsModelOrPixelEvidenceOrLegacyFrames() {
        var cadence = WallRecordingCadence()
        cadence.recorded(at: 10)
        for i in 1...5 {
            let t = 10 + Double(i) / 60
            XCTAssertTrue(cadence.shouldRecord(at: t, inferenceRan: true, hasBall: false, source: 0))
            XCTAssertTrue(cadence.shouldRecord(at: t, inferenceRan: false, hasBall: true, source: 5))
            XCTAssertTrue(cadence.shouldRecord(at: t, inferenceRan: false, hasBall: false, source: 5))
            XCTAssertTrue(cadence.shouldRecord(at: t, inferenceRan: nil, hasBall: false, source: 0))
        }
        XCTAssertFalse(cadence.shouldRecord(at: .nan, inferenceRan: true, hasBall: true, source: 5))
    }

    func testEncoderBackpressureDoesNotConsumeAnIdleRecordingSlot() {
        var cadence = WallRecordingCadence()
        cadence.recorded(at: 1)
        XCTAssertTrue(cadence.shouldRecord(at: 1.1, inferenceRan: false, hasBall: false, source: 0))
        // Writer unavailable: do not call recorded(at:). The next frame can try.
        XCTAssertTrue(cadence.shouldRecord(at: 1.1167, inferenceRan: false, hasBall: false, source: 0))
        cadence.recorded(at: 1.1167)
        XCTAssertFalse(cadence.shouldRecord(at: 1.1334, inferenceRan: false, hasBall: false, source: 0))
        XCTAssertTrue(cadence.shouldRecord(at: 0, inferenceRan: false, hasBall: false, source: 0))
    }

    func testNonInputPhaseRestsModelButDoesNotBlockReferenceOrFirstRecallFrame() {
        var cadence = WallInferenceCadence()
        for frame in 0..<120 {
            XCTAssertFalse(cadence.admit(at: Double(frame) / 30, scoring: true,
                collectingReference: false, referenceFinished: true, gameplayInputEnabled: false))
        }
        XCTAssertTrue(cadence.admit(at: 4, scoring: true,
            collectingReference: false, referenceFinished: true, gameplayInputEnabled: true))
        XCTAssertTrue(cadence.admit(at: 4.01, scoring: false,
            collectingReference: true, referenceFinished: false, gameplayInputEnabled: false))
        XCTAssertFalse(cadence.admit(at: 4.02, scoring: false,
            collectingReference: true, referenceFinished: false, gameplayInputEnabled: false))
    }

    func testSceneActivityWakesForSmallBallLargePlayerAndFlash() {
        var activity = WallSceneActivity(), cadence = WallGameplayInferenceCadence()
        let still = [UInt8](repeating: 80, count: 320 * 180)
        XCTAssertTrue(activity.hasMotion(luma: still, width: 320, height: 180, at: 0))
        XCTAssertTrue(cadence.admit(at: 0, motion: false, tracked: false, modelFrame: true))
        XCTAssertFalse(activity.hasMotion(luma: still, width: 320, height: 180, at: 0.03))
        for size in [(4, 3), (100, 100), (320, 180)] {
            activity.reset()
            _ = activity.hasMotion(luma: still, width: 320, height: 180, at: 0)
            var changed = still
            for y in 0..<size.1 { for x in 0..<size.0 { changed[y * 320 + x] += 12 } }
            let motion = activity.hasMotion(luma: changed, width: 320, height: 180, at: 0.033)
            XCTAssertTrue(motion)
            cadence.reset()
            _ = cadence.admit(at: 0, motion: false, tracked: false, modelFrame: true)
            XCTAssertTrue(cadence.admit(at: 0.033, motion: motion, tracked: false, modelFrame: true))
        }
    }

    func testIsolatedProjectorNoiseRestsButSmallCoherentMotionStillWakes() {
        var activity = WallSceneActivity()
        let still = [UInt8](repeating: 80, count: 320 * 180)
        _ = activity.hasMotion(luma: still, width: 320, height: 180, at: 0)
        var noise = still
        for y in stride(from: 10, to: 170, by: 10) {
            for x in stride(from: 10, to: 310, by: 10) { noise[y * 320 + x] = 150 }
        }
        XCTAssertFalse(activity.hasMotion(luma: noise, width: 320, height: 180, at: 0.017))
        // A ball can arrive during the noise; do not postpone it to the 4 Hz fallback.
        for y in 50..<54 { for x in 75..<79 { noise[y * 320 + x] = 180 } }
        XCTAssertTrue(activity.hasMotion(luma: noise, width: 320, height: 180, at: 0.033))
    }

    func testSceneActivityFailsOpenAfterGapsAndBadInput() {
        var activity = WallSceneActivity()
        let image = [UInt8](repeating: 80, count: 40)
        for t in [0.0, 1, 0.5, 0.5, .nan] {
            XCTAssertTrue(activity.hasMotion(luma: image, width: 10, height: 4, at: t))
        }
        XCTAssertTrue(activity.hasMotion(luma: image, width: 4, height: 10, at: 2))
        XCTAssertFalse(activity.hasMotion(luma: image, width: 4, height: 10, at: 2.03))
        XCTAssertTrue(activity.hasMotion(luma: [], width: 4, height: 10, at: 2.06))
        XCTAssertTrue(activity.hasMotion(luma: image, width: 4, height: 10, at: 2.09))
    }

    func testWaitingModelRestsButMotionWakesOnTheSameFrame() {
        var cadence = WallGameplayInferenceCadence()
        let runs = (0..<600).filter {
            cadence.admit(at: Double($0) / 60, motion: false, tracked: false, modelFrame: true)
        }
        XCTAssertEqual(runs.count, 40)
        XCTAssertTrue(cadence.admit(at: 10, motion: false, tracked: false, modelFrame: true))
        XCTAssertTrue(cadence.admit(at: 10.0167, motion: true, tracked: false, modelFrame: true))
        XCTAssertTrue(cadence.admit(at: 10.10, motion: false, tracked: false, modelFrame: true))
        XCTAssertFalse(cadence.admit(at: 10.22, motion: false, tracked: false, modelFrame: true))
    }

    func testBufferedMotionWakesNextModelAndMeasuredBallKeepsFullReboundWindow() {
        var cadence = WallGameplayInferenceCadence()
        XCTAssertTrue(cadence.admit(at: 1, motion: false, tracked: false, modelFrame: true))
        XCTAssertFalse(cadence.admit(at: 1.0167, motion: true, tracked: false, modelFrame: false))
        XCTAssertTrue(cadence.admit(at: 1.0334, motion: false, tracked: false, modelFrame: true))
        cadence.observedBall(at: 1.0334)
        for t in [1.12, 1.22, 1.32, 1.42, 1.52, 1.62, 1.68] {
            XCTAssertTrue(cadence.admit(at: t, motion: false, tracked: false, modelFrame: true))
        }
        XCTAssertFalse(cadence.admit(at: 1.70, motion: false, tracked: false, modelFrame: true))
        XCTAssertTrue(cadence.admit(at: 1.94, motion: false, tracked: false, modelFrame: true))
        cadence.reset()
        XCTAssertTrue(cadence.admit(at: 2, motion: false, tracked: false, modelFrame: true))
        XCTAssertFalse(cadence.admit(at: .nan, motion: true, tracked: true, modelFrame: true))
        XCTAssertFalse(cadence.admit(at: 2, motion: false, tracked: false, modelFrame: true))
        XCTAssertTrue(cadence.admit(at: 0, motion: false, tracked: false, modelFrame: true))
    }

    func testWorkReportCountsIntentionalWaitingSeparately() {
        var meter = WallWorkMeter(at: 0)
        meter.skippedIdleModelFrame(); meter.skippedIdleModelFrame()
        meter.skippedGamePhaseFrame()
        let sample = meter.take(at: 1)
        XCTAssertEqual(sample.idleModelFramesSkipped, 2)
        XCTAssertEqual(sample.referenceFramesSkipped, 0)
        XCTAssertEqual(sample.gamePhaseFramesSkipped, 1)
        let next = meter.take(at: 2)
        XCTAssertEqual(next.idleModelFramesSkipped, 0)
        XCTAssertEqual(next.gamePhaseFramesSkipped, 0)
    }
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
