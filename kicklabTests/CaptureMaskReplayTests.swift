import AVFoundation
import XCTest
@testable import kicklab

@MainActor
final class CaptureMaskReplayTests: XCTestCase {
    private func times(_ url: URL, composed: Bool) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output: AVAssetReaderOutput
        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if composed {
            let value = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
            value.videoComposition = try await EffectVideoGeometry.composition(track: track, duration: asset.load(.duration), shortEdge: 720)
            output = value
        } else { output = AVAssetReaderTrackOutput(track: track, outputSettings: settings) }
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result = [Double]()
        while let sample = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if time.isFinite, CMSampleBufferGetImageBuffer(sample) != nil { result.append(time) }
        }
        XCTAssertEqual(reader.status, .completed)
        return result
    }

    func testRecordedMasksAreReanalysedOnTheUploadClockWithoutChangingLiveStats() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "experimentalBallModel")
        defaults.set("motionModel", forKey: "experimentalBallModel")
        defer {
            if let previous { defaults.set(previous, forKey: "experimentalBallModel") }
            else { defaults.removeObject(forKey: "experimentalBallModel") }
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let rawTimes = try await times(url, composed: false)
        let renderTimes = try await times(url, composed: true)
        let mask = BallMask(rect: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), width: 2, height: 2, alpha: [255,255,255,255])
        let live = rawTimes.map { time in
            RecordedFrame(time: time, x: 0.45, y: 0.45, width: 0.1, height: 0.1, score: 0.9,
                smoothedX: 0.45, smoothedY: 0.45, vy: 0, motion: .unknown, detected: true,
                person: nil, ballMask: mask, usesBallMasks: true)
        }
        let oldTrack = BallEffectTrack(frames: live)
        let oldEligible = renderTimes.filter { oldTrack.mask(at: $0) != nil }.count
        XCTAssertLessThan(oldEligible, renderTimes.count / 2, "The fixture must reproduce the live/composition clock mismatch")
        let refined = try await BallVisualRefiner.refineVideo(source: url, frames: live)
        let uploaded = VideoAnalyzer()
        uploaded.analyse(url: url)
        let deadline = Date().addingTimeInterval(120)
        while uploaded.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(uploaded.isRunning)
        XCTAssertEqual(uploaded.status, "done")
        // Visual preparation no longer calculates touches. An import must not
        // mistake that artifact's deliberately absent count for a counted session.
        let expected = uploaded.recordedTrack
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(refined.map(\.time), expected.map(\.time))
        for (a, b) in zip(refined, expected) {
            XCTAssertEqual(a.x, b.x); XCTAssertEqual(a.y, b.y)
            XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
            XCTAssertEqual(a.score, b.score)
            XCTAssertEqual(a.ballMask?.rect, b.ballMask?.rect)
            XCTAssertEqual(a.ballMask?.alpha, b.ballMask?.alpha)
            XCTAssertEqual(a.usesBallMasks, b.usesBallMasks)
        }
        let visual = BallEffectTrack(frames: refined)
        let eligible = renderTimes.filter { visual.mask(at: $0) != nil }.count
        XCTAssertGreaterThan(eligible, oldEligible)
        XCTAssertTrue(refined.allSatisfy { row in renderTimes.contains { abs($0 - row.time) < 0.003 } })
        let marks = [RecordedTouch(index: 1, time: 0.4, x: 0.45, y: 0.45)]
        var summary = SessionSummary.make(touches: 7, duration: 2, bestCombo: 7, personalBest: 7,
            videoURL: url, touchesMarked: marks, track: live)
        summary.visualTrack = refined
        XCTAssertEqual(summary.touches, 7)
        XCTAssertEqual(summary.touchesMarked, marks)
        XCTAssertEqual(summary.track.map(\.time), rawTimes)
        let report: [String: Any] = ["source_frames": rawTimes.count, "render_frames": renderTimes.count,
            "before_eligible_masks": oldEligible, "after_eligible_masks": eligible,
            "upload_track_and_masks_identical": true, "live_stats_retained": true]
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
            .write(to: URL.documentsDirectory.appendingPathComponent("capture-mask-replay-test.json"))
    }

    func testCancelledReplayAnalysisDoesNotReturnAStaleTrack() async throws {
        let task = Task { try await VideoAnalyzer.replayTrack(source: URL(fileURLWithPath: "/missing.mov")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis must throw") }
        catch is CancellationError { }
    }

    func testStillPreviewUsesCompositionPixelsAndExactMaskClock() async throws {
        for name in ["capture-mask-vfr", "capture-sixty"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mov"))
            let renderTimes = try await times(url, composed: true)
            let asset = AVURLAsset(url: url)
            let mask = BallMask(rect: CGRect(x:0.4,y:0.4,width:0.1,height:0.1), width:2,height:2,alpha:[255,255,255,255])
            let frames = renderTimes.map { time in RecordedFrame(time:floor(time*1000)/1000,
                x:0.45,y:0.45,width:0.1,height:0.1,score:0.9,smoothedX:0.45,smoothedY:0.45,
                vy:0,motion:.unknown,detected:true,person:nil,ballMask:mask,usesBallMasks:true) }
            let visual = BallEffectTrack(frames:frames)
            for requested in [0.025,0.35,0.515,0.877,1.225] {
                let still = try await EffectVideoGeometry.still(asset:asset,at:requested)
                let time = CMTimeGetSeconds(still.actualTime)
                XCTAssertNotNil(visual.mask(at:time), "\(name): still \(time) is off the composition clock")
                XCTAssertTrue(renderTimes.contains { abs($0-time) < 0.003 })
                XCTAssertGreaterThan(still.image.width,0)
            }
        }
    }

    func testImportedCompositionTrackKeepsExistingInferenceAndStatistics() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let mask = BallMask(rect: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1),
            width: 2, height: 2, alpha: [255, 255, 255, 255])
        let frame = RecordedFrame(time: 0.25, x: 0.45, y: 0.45, width: 0.1, height: 0.1,
            score: 0.987, smoothedX: 0.45, smoothedY: 0.45, vy: 0, motion: .unknown,
            detected: true, person: nil, ballMask: mask, usesBallMasks: true)
        let marks = [RecordedTouch(index: 1, time: 0.4, x: 0.45, y: 0.45)]
        var summary = SessionSummary.make(touches: 7, duration: 2, bestCombo: 7, personalBest: 7,
            videoURL: url, touchesMarked: marks, track: [frame])
        summary.visualTrack = try await BallVisualRefiner.refineVideo(source: url, frames: summary.track,
            framesUseCompositionClock: true)
        // A fresh inference would replace this deliberately distinctive input.
        XCTAssertEqual(summary.renderTrack.count, 1)
        XCTAssertEqual(summary.renderTrack[0].time, frame.time)
        XCTAssertEqual(summary.renderTrack[0].score, frame.score)
        XCTAssertEqual(summary.renderTrack[0].ballMask?.alpha, mask.alpha)
        XCTAssertEqual(summary.touches, 7)
        XCTAssertEqual(summary.touchesMarked, marks)
        XCTAssertEqual(summary.track[0].score, frame.score)
    }
}
