import AVFoundation
import MediaPipeTasksVision
import UIKit
import XCTest
@testable import kicklab

/// Exercise the real graph so a successful link cannot hide missing static
/// registrations or Objective-C categories behind the counter's safe fallback.
final class MediaPipeLinkageTests: XCTestCase {
    func testRealVideoPoseGraphProducesAllFootLandmarks() throws {
        try XCTSkipUnless(ShoeRecoveryPolicy.available)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let landmarker = try makeLandmarker()
        let asset = AVURLAsset(url: source)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var nextMilliseconds = 0
        var rows: [[String: Any]] = []
        var detected = 0
        let recovery = ShoeContactRecovery()
        var processed = 0
        while let sample = output.copyNextSampleBuffer() {
            let milliseconds = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000).rounded())
            guard milliseconds >= nextMilliseconds else { continue }
            if milliseconds > 18000 { break }
            nextMilliseconds += 200
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            let input = try MPImage(pixelBuffer: pixels, orientation: .up)
            let result = try landmarker.detect(videoFrame: input, timestampInMilliseconds: milliseconds)
            recovery.store(pixels, timestampMs: milliseconds, ball: nil, orientLandscapeAsPortrait: false)
            processed += 1
            if let pose = result.landmarks.first {
                XCTAssertEqual(pose.count, 33)
                XCTAssertEqual(result.worldLandmarks.first?.count, 33)
                for index in [27, 28, 29, 30, 31, 32] {
                    XCTAssertTrue(pose[index].x.isFinite && pose[index].y.isFinite)
                    XCTAssertNotNil(pose[index].visibility)
                    XCTAssertNotNil(pose[index].presence)
                }
                detected += 1
                rows.append(["ms": milliseconds, "pose": pose.map {
                    [Double($0.x), Double($0.y), Double($0.z),
                     $0.visibility?.doubleValue ?? -1, $0.presence?.doubleValue ?? -1]
                }])
            }
        }
        XCTAssertEqual(processed, 90)
        XCTAssertEqual(recovery.calls, processed)
        XCTAssertEqual(recovery.errors, 0)
        let performance = recovery.performance
        XCTAssertEqual(performance.calls, processed)
        XCTAssertGreaterThan(performance.loadMS, 0)
        XCTAssertGreaterThan(performance.inferenceMS, 0)
        XCTAssertGreaterThanOrEqual(performance.totalMS, performance.loadMS + performance.inferenceMS)
        XCTAssertGreaterThanOrEqual(performance.maxInferenceMS, performance.meanInferenceMS)
        XCTAssertGreaterThanOrEqual(performance.framesWithPose, 60)
        XCTAssertNotNil(performance.appMemoryBeforeLoadMiB)
        XCTAssertNotNil(performance.appMemoryAfterLoadMiB)
        recovery.reset()
        XCTAssertEqual(recovery.performance.calls, 0)
        XCTAssertEqual(recovery.performance.totalMS, 0)
        XCTAssertEqual(recovery.performance.inferenceMS, 0)
        XCTAssertEqual(recovery.performance.loadMS, 0)
        XCTAssertNil(recovery.performance.appMemoryBeforeLoadMiB)
        XCTAssertGreaterThanOrEqual(detected, 60, "The actual pose graph must detect the visible player")
        let json = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "real-video-pose-landmarks.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MEDIAPIPE_LINKAGE frames=\(processed) detected=\(detected)")
    }

    func testTrackingLossReacquisitionAndNewSessions() throws {
        try XCTSkipUnless(ShoeRecoveryPolicy.available)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let asset = AVURLAsset(url: source)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let visible = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        reader.cancelReading()
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,
            CVPixelBufferGetWidth(visible), CVPixelBufferGetHeight(visible),
            kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let blank = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(blank, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(blank))
        memset(bytes, 0, CVPixelBufferGetBytesPerRow(blank) * CVPixelBufferGetHeight(blank))
        CVPixelBufferUnlockBaseAddress(blank, [])
        var rows: [[String: Any]] = []
        let recovery = ShoeContactRecovery()
        for session in 0..<2 {
            let landmarker = try makeLandmarker()
            recovery.reset()
            var detections = 0, absent = 0, reacquired = 0
            for frame in 0..<60 {
                let hidden = (20..<40).contains(frame)
                let pixels = hidden ? blank : visible
                let result = try landmarker.detect(videoFrame: MPImage(pixelBuffer: pixels, orientation: .up),
                    timestampInMilliseconds: frame * 100)
                recovery.store(pixels, timestampMs: frame * 100, ball: nil, orientLandscapeAsPortrait: false)
                let pose = result.landmarks.first ?? []
                if hidden && pose.isEmpty { absent += 1 }
                if !hidden && pose.count == 33 {
                    detections += 1
                    if frame >= 40 { reacquired += 1 }
                }
                rows.append(["session": session, "frame": frame, "hidden": hidden,
                    "pose": pose.map { [Double($0.x), Double($0.y), Double($0.z),
                        $0.visibility?.doubleValue ?? -1, $0.presence?.doubleValue ?? -1] }])
            }
            XCTAssertGreaterThanOrEqual(detections, 30)
            XCTAssertGreaterThanOrEqual(absent, 15)
            XCTAssertGreaterThanOrEqual(reacquired, 15)
            XCTAssertEqual(recovery.calls, 60)
            XCTAssertEqual(recovery.errors, 0)
            print("MEDIAPIPE_LIFECYCLE session=\(session) visible=\(detections) absent=\(absent) reacquired=\(reacquired)")
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "pose-lifecycle-landmarks.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeLandmarker() throws -> PoseLandmarker {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task"))
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = .CPU
        options.runningMode = .video
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.shouldOutputSegmentationMasks = false
        return try PoseLandmarker(options: options)
    }
}
