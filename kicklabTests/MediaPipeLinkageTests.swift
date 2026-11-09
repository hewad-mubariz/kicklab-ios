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
        let landmarker = try PoseLandmarker(options: options)
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
            if milliseconds > 4000 { break }
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
        XCTAssertEqual(processed, 20)
        XCTAssertEqual(recovery.calls, processed)
        XCTAssertEqual(recovery.errors, 0)
        XCTAssertGreaterThanOrEqual(detected, 15, "The actual pose graph must detect the visible player")
        let json = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "real-video-pose-landmarks.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MEDIAPIPE_LINKAGE frames=\(processed) detected=\(detected)")
    }
}
