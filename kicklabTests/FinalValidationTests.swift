import Foundation
import XCTest
@testable import kicklab

#if DEBUG
final class FinalValidationTests: XCTestCase {
    func testCompletedPipelineStillNeedsIndependentVisualReview() {
        var report = makeReport()
        for name in FinalTestReport.stageNames {
            report.stages[name]?.status = name == "replay" ? "opened" : "completed"
        }
        XCTAssertEqual(report.verdict, "pending validation")
        for name in FinalTestReport.reviewNames { report.reviews[name] = "passed" }
        XCTAssertEqual(report.verdict, "reviewed pass")
        report.stages["recording"]?.status = "short"
        XCTAssertEqual(report.verdict, "needs attention", "A short recording cannot satisfy the duration gate")
        report.stages["recording"]?.status = "completed"
        report.storageError = "disk full"
        XCTAssertEqual(report.verdict, "needs attention")
    }

    func testInterruptedStageIsRetainedAndNeverCountedAsCompleted() {
        var report = makeReport()
        report.stages["recording"]?.status = "completed"
        report.stages["analysis"]?.status = "running"
        report.liveTouches = 42
        report.recoverInterruptedStages()
        XCTAssertEqual(report.stages["analysis"]?.status, "interrupted")
        XCTAssertEqual(report.stages["recording"]?.status, "completed")
        XCTAssertEqual(report.liveTouches, 42)
        XCTAssertEqual(report.verdict, "needs attention")
    }

    func testJournalRetainsAllDecisionsAfterNumericTraceLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinalTestFiles(directory: directory)
        let counter = StreamingCounter(recordTrace: true, traceLimit: 4, diagnoseContact: { decision, ball in
            TouchDebugEvent(frameIndex: decision.frameIndex, time: Double(decision.frameIndex) / 30,
                rejection: decision.rejection, handConfirmed: false, bodyFailure: nil, ball: ball)
        })
        counter.debugDiagnosticObserver = { store.append($0, to: "contacts.jsonl") }
        // Replay a real ball trajectory into a deliberately tiny bounded trace.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/low-toe-taps-counter-v7.plist")
        let trace = try PropertyListDecoder().decode(CounterTrace.self, from: Data(contentsOf: fixture))
        var observed = 0
        counter.debugDiagnosticObserver = { event in observed += 1; store.append(event, to: "contacts.jsonl") }
        for operation in trace.operations {
            if let input = operation.input {
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: input.ball,
                    person: input.person, cameraOffsetY: input.cameraOffsetY, reliable: input.reliable)
            }
            if operation.flush { counter.flush() }
        }
        counter.flush()
        await store.flush()
        XCTAssertFalse(try XCTUnwrap(counter.traceSnapshot()).complete)
        XCTAssertGreaterThan(observed, 4)
        let lines = try String(contentsOf: directory.appendingPathComponent("contacts.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, observed)
        for line in lines { _ = try JSONDecoder().decode(TouchDebugEvent.self, from: Data(line.utf8)) }
    }

    private func makeReport() -> FinalTestReport {
        FinalTestReport(id: UUID(), targetSeconds: 900, started: Date(), updated: Date(),
                        build: "test", device: "test", os: "test", model: "test", pipeline: "test")
    }
}
#endif
