import CoreVideo
import Foundation
import MediaPipeTasksVision
import UIKit

/// Serial analysis-queue owned. Uses CPU on both sides of a background transition.
/// Failure or missing/late landmarks only removes auxiliary evidence, never the
/// established ball counter. No image or model output leaves the device.
nonisolated final class ShoeContactRecovery {
    private let enabled = ShoeRecoveryPolicy.enabled
    private var landmarker: PoseLandmarker?
    private var failed = false
    private var latestMs = -1
    private var samples: [ShoeContactProof.Sample] = []
    private(set) var calls = 0
    private(set) var errors = 0
    private(set) var milliseconds = 0.0
    private(set) var proofRequests = 0
    private(set) var proofs = 0
    var metrics: [String: Double] {
        ["shoe_enabled": enabled ? 1 : 0, "shoe_calls": Double(calls),
         "shoe_errors": Double(errors), "shoe_ms": milliseconds,
         "shoe_proof_requests": Double(proofRequests), "shoe_proofs": Double(proofs)]
    }
    func discardFrames() { samples.removeAll(keepingCapacity: true) }
    func reset() {
        discardFrames(); landmarker = nil; failed = false; latestMs = -1
        calls = 0; errors = 0; milliseconds = 0; proofRequests = 0; proofs = 0
    }
    func store(_ pixels: CVPixelBuffer, timestampMs: Int, ball: Detection?, orientLandscapeAsPortrait: Bool) {
        guard enabled, !failed, timestampMs >= 0, timestampMs > latestMs else { return }
        latestMs = timestampMs
        samples.removeAll { timestampMs-$0.ms > 1_000 }
        let start = ProcessInfo.processInfo.systemUptime
        defer { milliseconds += (ProcessInfo.processInfo.systemUptime-start)*1_000 }
        do {
            if landmarker == nil {
                guard let path = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") else {
                    failed = true; errors += 1; return
                }
                let options = PoseLandmarkerOptions()
                options.baseOptions.modelAssetPath = path
                options.baseOptions.delegate = .CPU
                options.runningMode = .video
                options.numPoses = 1
                options.minPoseDetectionConfidence = 0.5
                options.minPosePresenceConfidence = 0.5
                options.minTrackingConfidence = 0.5
                options.shouldOutputSegmentationMasks = false
                landmarker = try PoseLandmarker(options: options)
            }
            let rotate = orientLandscapeAsPortrait && CVPixelBufferGetWidth(pixels) > CVPixelBufferGetHeight(pixels)
            let image = try MPImage(pixelBuffer: pixels, orientation: rotate ? .right : .up)
            calls += 1
            let result = try landmarker!.detect(videoFrame: image, timestampInMilliseconds: timestampMs)
            guard let pose = result.landmarks.first, pose.count == 33, let ball else { return }
            let points = pose.map { ShoeContactProof.Point(x: Double($0.x), y: Double($0.y),
                visibility: $0.visibility?.doubleValue ?? 0, presence: $0.presence?.doubleValue ?? 0) }
            samples.append(.init(ms: timestampMs, pose: points,
                ball: .init(x: ball.x, y: ball.y, width: ball.width, height: ball.height, confidence: ball.score)))
        } catch {
            // Do not retry a broken graph every frame or poison Vision's error state.
            errors += 1; failed = true; landmarker = nil; samples.removeAll()
        }
    }
    func proof(at time: Int, through now: Int, player: ActivePlayerSelection?) -> ShoeContactProof? {
        guard enabled, !failed else { return nil }
        proofRequests += 1
        let result = ShoeContactRules.proof(samples, at: time, through: now, player: player)
        if result != nil { proofs += 1 }
        return result
    }
}
