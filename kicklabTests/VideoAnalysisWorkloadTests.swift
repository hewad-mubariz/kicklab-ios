import XCTest
import UIKit
@testable import kicklab

final class VideoAnalysisWorkloadTests: XCTestCase {
    private actor Probe {
        var active = 0
        var peak = 0
        var calls = 0
        var cooling = false
        func enter() { active += 1; calls += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
        func setCooling(_ value: Bool) { cooling = value }
    }
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ProcessInfo.ThermalState = .critical
        func read() -> ProcessInfo.ThermalState { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: ProcessInfo.ThermalState) { lock.lock(); defer { lock.unlock() }; self.value = value }
    }

    func testConcurrentVideoRequestsNeverOverlap() async throws {
        let scheduler = VideoAnalysisScheduler(), probe = Probe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await scheduler.perform {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(15))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await probe.peak, calls = await probe.calls
        XCTAssertEqual(peak, 1); XCTAssertEqual(calls, 6)
    }

    func testCancelledWaiterNeverStartsAndActiveCancellationReleasesNextVideo() async throws {
        let scheduler = VideoAnalysisScheduler(), probe = Probe()
        let first = Task {
            try await scheduler.perform {
                await probe.enter()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { await probe.leave(); throw error }
                await probe.leave()
            }
        }
        while await probe.active == 0 { await Task.yield() }
        let second = Task { try await scheduler.perform { await probe.enter(); await probe.leave() } }
        while await scheduler.queuedCount == 0 { await Task.yield() }
        second.cancel()
        do { try await second.value; XCTFail("Cancelled video ran") } catch is CancellationError {}
        let third = Task { try await scheduler.perform { await probe.enter(); await probe.leave() } }
        first.cancel()
        do { try await first.value; XCTFail("Active cancellation was swallowed") } catch is CancellationError {}
        try await third.value
        let peak = await probe.peak, calls = await probe.calls
        XCTAssertEqual(peak, 1); XCTAssertEqual(calls, 2)
    }

    func testCriticalPauseResumesBeforeAnyFrameWorkAndCanBeCancelled() async throws {
        let state = State(), probe = Probe()
        let task = Task {
            var pacer = VideoAnalysisPacer(thermalState: { state.read() }, isBackground: { false })
            _ = try await pacer.beginFrame { await probe.setCooling($0) }
            await probe.enter()
            return pacer.waitingSeconds
        }
        while !(await probe.cooling) { await Task.yield() }
        let before = await probe.calls; XCTAssertEqual(before, 0)
        state.set(.nominal)
        let waited = try await task.value
        let cooling = await probe.cooling, calls = await probe.calls
        XCTAssertFalse(cooling); XCTAssertEqual(calls, 1); XCTAssertGreaterThan(waited, 0.5)

        state.set(.critical)
        let cancelled = Task {
            var pacer = VideoAnalysisPacer(thermalState: { state.read() }, isBackground: { false })
            _ = try await pacer.beginFrame { await probe.setCooling($0) }
            XCTFail("Critical pause admitted more work")
        }
        while !(await probe.cooling) { await Task.yield() }
        let start = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Pause ignored cancellation") } catch is CancellationError {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testBackgroundPauseDoesNotAdmitFrameAndElevatedPressureYields() async throws {
        let probe = Probe()
        let task = Task {
            var pacer = VideoAnalysisPacer(thermalState: { .nominal }, isBackground: { true })
            _ = try await pacer.beginFrame { _ in }
            await probe.enter()
        }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { try await task.value; XCTFail("Background work was admitted") } catch is CancellationError {}
        let calls = await probe.calls; XCTAssertEqual(calls, 0)
        for state in [ProcessInfo.ThermalState.fair, .serious] {
            var pacer = VideoAnalysisPacer(thermalState: { state }, isBackground: { false })
            for _ in 0..<8 {
                let start = try await pacer.beginFrame { _ in }
                // Stand in for eight completed 20 ms frames, retaining all of
                // them while the accumulated budget yields less often.
                try await pacer.finishFrame(started: start - 0.02)
            }
            XCTAssertGreaterThan(pacer.waitingSeconds, 0.04)
            XCTAssertLessThan(pacer.pacingSleeps, 8)
        }
        var normal = VideoAnalysisPacer(thermalState: { .nominal }, isBackground: { false })
        let start = try await normal.beginFrame { _ in }
        try await normal.finishFrame(started: start - 0.02)
        XCTAssertEqual(normal.waitingSeconds, 0)
    }

    @MainActor
    func testRealImportCancellationStopsProgressAndAllowsAnotherRequest() async throws {
        let source = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let analyzer = VideoAnalyzer()
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        analyzer.analyse(url: source)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while analyzer.isRunning && analyzer.framesRead < 15 && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(analyzer.isRunning, "This test requires a fresh analysis, not a cache hit")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        let start = ProcessInfo.processInfo.systemUptime
        analyzer.cancel(); await analyzer.waitUntilFinished()
        XCTAssertEqual(analyzer.status, "cancelled")
        XCTAssertFalse(analyzer.isRunning)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, previousIdle)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        let stoppedFrames = analyzer.framesRead
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(analyzer.framesRead, stoppedFrames)
        XCTAssertTrue(analyzer.recordedTrack.isEmpty, "An interrupted pass must not publish a complete track")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        // A subsequent request must execute and report its own failure, rather
        // than being blocked behind the abandoned model pass.
        analyzer.analyse(url: URL(fileURLWithPath: "/does-not-exist-\(UUID()).mov"))
        await analyzer.waitUntilFinished()
        XCTAssertTrue(analyzer.status.hasPrefix("failed:"))
        XCTAssertFalse(analyzer.isRunning)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, previousIdle)
    }
}
