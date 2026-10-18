#if DEBUG
import AVFoundation
import XCTest
@testable import kicklab

final class DebugFrameSamplingTests: XCTestCase {
    private func sample(_ profile: DebugFrameProfile, sourceFPS: Double = 60,
                        frames: Int = 600) -> (times: [Double], sampler: DebugFrameSampling) {
        var sampler = DebugFrameSampling(profile: profile)
        var buffer = LiveAnalysisBuffer<Double>()
        var times: [Double] = []
        for index in 0..<frames {
            let sourceTime = 100_000 + Double(index) / sourceFPS
            if sampler.allows(sourceTime), let frame = buffer.offer(sourceTime, at: sourceTime) {
                times.append(frame)
                XCTAssertNil(buffer.finish())
            }
        }
        return (times, sampler)
    }

    func testNormalModePreservesExistingSelectionIncludingTimestampJitter() {
        var baseline = LiveAnalysisBuffer<Int>(), tested = LiveAnalysisBuffer<Int>()
        var sampler = DebugFrameSampling(profile: .normal)
        for i in 0..<600 {
            let time = 80 + Double(i) / 59.94 + (i.isMultiple(of: 7) ? 0.0002 : 0)
            let expected = baseline.offer(i, at: time)
            XCTAssertTrue(sampler.allows(time))
            XCTAssertEqual(tested.offer(i, at: time), expected)
            XCTAssertEqual(tested.finish(), baseline.finish())
        }
        XCTAssertEqual(sampler.skipped, 0)
        XCTAssertEqual(tested.throttled, baseline.throttled)
    }

    func testProfilesKeepOriginalTimestampsAtSixtyAndThirtyFPS() {
        for sourceFPS in [60.0, 59.94, 30.0, 29.97] {
            let frameCount = Int(sourceFPS.rounded()) * 10
            for profile in [DebugFrameProfile.normal, .fps20, .fps15, .fps10] {
                let result = sample(profile, sourceFPS: sourceFPS, frames: frameCount)
                XCTAssertEqual(result.times.count, Int(profile.framesPerSecond * 10), "\(profile) at \(sourceFPS)")
                XCTAssertEqual(result.times.first, 100_000)
                for time in result.times {
                    let sourceIndex = (time - 100_000) * sourceFPS
                    XCTAssertEqual(sourceIndex, sourceIndex.rounded(), accuracy: 0.00001)
                }
                XCTAssertEqual(result.sampler.gapSkipped, 0)
            }
        }
    }

    func testRepeatableGapsSkipTwoHundredMillisecondsWithoutCatchup() {
        for profile in [DebugFrameProfile.gaps30, .gaps15] {
            let result = sample(profile)
            XCTAssertEqual(result.times, sample(profile).times)
            XCTAssertEqual(result.sampler.gapSkipped, 36) // 12 source frames per gap, three gaps.
            XCTAssertEqual(result.times.count, profile == .gaps30 ? 282 : 141)
            for time in result.times {
                let relative = time - 100_000
                for start in [3.0, 6, 9] {
                    XCTAssertFalse(relative >= start - 0.00001 && relative < start + 0.19999)
                }
            }
            let deltas = zip(result.times, result.times.dropFirst()).map { $1 - $0 }
            XCTAssertGreaterThan(deltas.max()!, 0.2)
            XCTAssertGreaterThanOrEqual(deltas.min()!, 1 / profile.framesPerSecond - 0.00001)
        }
    }

    func testLongRealGapInvalidTimestampsAndNewTakeDoNotProduceCatchup() {
        var sampler = DebugFrameSampling(profile: .fps15)
        XCTAssertFalse(sampler.allows(.nan))
        XCTAssertFalse(sampler.allows(.infinity))
        XCTAssertTrue(sampler.allows(10))
        XCTAssertFalse(sampler.allows(10))
        XCTAssertFalse(sampler.allows(9))
        XCTAssertTrue(sampler.allows(15))
        XCTAssertFalse(sampler.allows(15 + 1.0 / 60))
        sampler = .init(profile: .gaps30)
        XCTAssertTrue(sampler.allows(500))
        XCTAssertFalse(sampler.allows(503))
        sampler = .init(profile: .gaps30)
        XCTAssertTrue(sampler.allows(503), "Each take gets a fresh timing origin")
        XCTAssertEqual(sampler.skipped, 0)
    }

    func testSlowWorkerStillKeepsOneNewestFrameAndCancellationReleasesIt() {
        var sampler = DebugFrameSampling(profile: .fps15)
        var buffer = LiveAnalysisBuffer<Int>()
        var latest = -1
        for i in 0..<600 {
            let time = Double(i) / 60
            guard sampler.allows(time) else { continue }
            latest = i
            if i == 0 { XCTAssertEqual(buffer.offer(i, at: time), 0) }
            else { XCTAssertNil(buffer.offer(i, at: time)) }
        }
        XCTAssertEqual(buffer.pending, latest)
        XCTAssertEqual(buffer.replaced, 148)
        buffer.cancelPending()
        XCTAssertNil(buffer.finish())
        XCTAssertFalse(buffer.isRunning)
    }

    func testDiagnosticsSeparateSimulatedSkipsFromRealDropsAndUseSourceGaps() throws {
        var run = DebugFrameTestRun(profile: .fps15)
        var capture = CaptureCadenceSnapshot()
        capture.captureDrops = 2
        for i in 0...60 {
            let time = Double(i) / 60
            if run.allows(time) { run.submitted(at: time) }
            _ = run.observe(at: time, capture: capture, writerDrops: 3, replaced: 4)
        }
        let stats = run.snapshot
        XCTAssertEqual(stats.receivedFPS, 60, accuracy: 0.001)
        XCTAssertEqual(stats.rateSkipped, 45)
        XCTAssertEqual(stats.gapSkipped, 0)
        XCTAssertEqual(stats.captureDrops, 2)
        XCTAssertEqual(stats.writerDrops, 3)
        XCTAssertEqual(stats.replaced, 4)
        XCTAssertEqual(stats.maxAnalysisGapMS, 1_000 / 15, accuracy: 0.001)
        let decoded = try JSONDecoder().decode(DebugFrameTestSnapshot.self, from: JSONEncoder().encode(stats))
        XCTAssertEqual(decoded.profile, .fps15)
        XCTAssertEqual(decoded.skipped, 45)
        run = .init(profile: .normal)
        XCTAssertEqual(run.snapshot.skipped, 0)
        XCTAssertEqual(run.snapshot.maxAnalysisGapMS, 0)
    }

    #if TOUCH_COUNTING_DEBUG
    @MainActor
    func testLiveProfilesKeepRecordingCadenceAndLockSelectionDuringTake() async throws {
        try XCTSkipUnless(AVCaptureDevice.default(for: .video) != nil, "Requires a physical camera")
        let camera = CameraSession()
        defer { camera.stop() }
        camera.start()
        try await waitFor { camera.isReady && camera.isTrackingReady }
        let captureFPS = camera.capturePerformance.selectedFPS
        for profile in [DebugFrameProfile.normal, .fps15, .gaps15] {
            camera.setDebugFrameProfile(profile)
            camera.prepareTracking()
            try await waitFor { camera.canRecord }
            camera.startRecording()
            camera.setDebugFrameProfile(.fps10)
            XCTAssertEqual(camera.debugFrameProfile, profile, "Cannot change a running experiment")
            try await waitFor { camera.isRecording }
            try await Task.sleep(for: .milliseconds(4_400))
            camera.stopRecording()
            try await waitFor { !camera.isFinishingRecording }
            XCTAssertNil(camera.recordingError)
            let file = try XCTUnwrap(camera.recordingURL)
            defer { try? FileManager.default.removeItem(at: file) }
            let asset = AVURLAsset(url: file)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let fps = try await track.load(.nominalFrameRate)
            XCTAssertEqual(Double(fps), Double(captureFPS), accuracy: 1)
            let capture = camera.capturePerformance
            XCTAssertEqual(capture.selectedFPS, captureFPS)
            XCTAssertGreaterThan(capture.analysedFrames, 0)
            XCTAssertGreaterThan(capture.writtenFrames, capture.analysedFrames)
            XCTAssertGreaterThan(Double(capture.writtenFrames) / capture.duration, Double(captureFPS) * 0.85)
            XCTAssertLessThanOrEqual(Double(capture.analysedFrames) / capture.duration, profile.framesPerSecond + 1)
            XCTAssertEqual(camera.debugFrameTest.profile, profile)
            if profile == .normal { XCTAssertEqual(camera.debugFrameTest.skipped, 0) }
            else { XCTAssertGreaterThan(camera.debugFrameTest.rateSkipped, 0) }
            if profile.hasGaps {
                XCTAssertGreaterThan(camera.debugFrameTest.gapSkipped, 0)
                XCTAssertGreaterThan(camera.debugFrameTest.maxAnalysisGapMS, 190)
            } else { XCTAssertEqual(camera.debugFrameTest.gapSkipped, 0) }
            camera.clearRecording()
        }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), "Timed out waiting for capture")
        if !condition() { throw NSError(domain: "FrameTestCapture", code: 1) }
    }
    #endif
}
#endif
