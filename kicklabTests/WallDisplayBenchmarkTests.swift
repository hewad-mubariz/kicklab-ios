#if WALL_GAMES_PREVIEW
import XCTest
@testable import kicklab

final class WallDisplayBenchmarkTests: XCTestCase {
    /// Synthetic transport only: these are algorithm fixtures, never device results.
    private func simulate(latency: Double = 0.2, deliveryLag: Double = 0,
                          contrast: Double = 130, loseFlashes: Bool = false,
                          flicker: Bool = false, dropEdges: Bool = false) -> WallDisplayBenchmarkEngine {
        var engine = WallDisplayBenchmarkEngine(at: 100)
        for index in 0..<7_200 {
            let capture = 100+Double(index)/60
            let now = capture+deliveryLag
            engine.advance(to: now)
            if engine.finished { break }
            let command = engine.commands.last { $0.time <= capture-latency }
            let white = command?.lit == true && !(loseFlashes && engine.dark != nil && engine.bright != nil)
            if dropEdges, engine.phase == .waiting, let last = engine.commands.last,
               capture > last.time+latency-0.14, capture < last.time+latency { continue }
            var level = white ? 30+contrast : 30
            if flicker, engine.phase == .waiting, index % 17 == 0 { level = 30+contrast }
            engine.receive(.init(captureTime: capture, receivedTime: now, brightness: level,
                                 exposure: 1/240, iso: 200), now: now)
        }
        return engine
    }

    func testKnownDelayIsRecoveredWithinOneCameraFrame() {
        let result = simulate()
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.detected.count, 12)
        for delay in result.detected { XCTAssertEqual(delay, 200, accuracy: 17) }
        XCTAssertFalse(result.lit)
    }

    func testCallbackQueueDelayDoesNotBecomeMeasuredDisplayDelay() {
        let result = simulate(deliveryLag: 0.12)
        XCTAssertTrue(result.valid)
        for delay in result.detected { XCTAssertEqual(delay, 200, accuracy: 17) }
    }

    func testSingleFrameFlickerDoesNotTriggerAnEarlyResult() {
        let result = simulate(latency: 0.35, flicker: true)
        XCTAssertTrue(result.valid)
        for delay in result.detected { XCTAssertEqual(delay, 350, accuracy: 34) }
    }

    func testInsufficientContrastProducesNoDelayClaim() {
        let result = simulate(contrast: 12)
        XCTAssertEqual(result.phase, .failed)
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.detected.isEmpty)
        XCTAssertFalse(result.lit)
    }

    func testMissingFlashesAreTimeoutsNotInventedMeasurements() {
        let result = simulate(loseFlashes: true)
        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(result.samples.count, 12)
        XCTAssertTrue(result.samples.allSatisfy { $0.status == "timeout" })
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.detected.isEmpty)
    }

    func testLargeCaptureGapsAreRejected() {
        let result = simulate(dropEdges: true)
        XCTAssertTrue(result.samples.allSatisfy { $0.status == "capture_gap" })
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.detected.isEmpty)
    }

    func testNoCameraAndCancellationBothEndWithoutLeavingWhitePatch() {
        var absent = WallDisplayBenchmarkEngine(at: 100)
        absent.advance(to: 103.1)
        XCTAssertEqual(absent.phase, .failed)
        XCTAssertFalse(absent.valid)
        var cancelled = WallDisplayBenchmarkEngine(at: 100)
        cancelled.cancel(at: 100.5)
        cancelled.receive(.init(captureTime: 101, receivedTime: 101, brightness: 255,
                                exposure: 0.004, iso: 100), now: 101)
        XCTAssertEqual(cancelled.phase, .failed)
        XCTAssertTrue(cancelled.observations.isEmpty)
        XCTAssertFalse(cancelled.lit)
    }

    func testEvidenceRoundTripsWithCaptureTimesAndSourceCommands() throws {
        let engine = simulate()
        let report = WallDelayReport(id: UUID(), date: Date(), connection: "Synthetic test fixture",
            device: "unit test", os: "unit test", build: "unit test", thermalStart: 0, thermalEnd: 0,
            roi: [0.5, 0.5, 0.04, 0.04], exposureLocked: true, valid: engine.valid,
            outcome: engine.message, dark: engine.dark, bright: engine.bright,
            commands: engine.commands, samples: engine.samples, observations: engine.observations)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(WallDelayReport.self, from: data)
        XCTAssertEqual(decoded.commands.count, engine.commands.count)
        XCTAssertEqual(decoded.observations.count, engine.observations.count)
        XCTAssertEqual(try XCTUnwrap(decoded.median), 200, accuracy: 17)
        XCTAssertEqual(try XCTUnwrap(decoded.frameInterval), 1000/60, accuracy: 0.01)
    }
}
#endif
