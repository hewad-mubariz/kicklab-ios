#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// On-device regression harness for explicitly staged local recordings. Replay
/// exact saved pixels + frozen detections through Vision with the previous
/// body policies, or old/new ground checks when config comparison is "ground".
/// Never changes saved counts.
/// Launch with --touch-contact-replay <folder-name> under Documents; config.json
/// lists clips with id/video/trace basenames. Results stay inside that folder.
nonisolated enum TouchContactReplay {
    private struct Configuration: Decodable {
        enum Comparison: String, Decodable {
            case body, ground, groundContinuity, footMotion, poseContinuity, handling, poseConfidence, contactTiming, legMotion, legRouting, temporalEvidence, completedRise, pixelFoot, observedImpact, independentLeg, ballAssociation, legRebound, trajectoryTiming, selectedPose, raisedFoot, footEvidence

            func policy(after: Bool) -> CountingPolicy {
                let ground: GroundContactPolicy
                switch self {
                case .ground: ground = after ? .plantedFeet : .supportedBoundary
                case .groundContinuity: ground = after ? .corroboratedFeet : .plantedFeet
                case .footMotion, .poseContinuity, .handling, .poseConfidence, .contactTiming, .legMotion, .legRouting, .temporalEvidence, .completedRise, .pixelFoot, .observedImpact, .independentLeg, .ballAssociation, .legRebound, .trajectoryTiming, .selectedPose, .raisedFoot, .footEvidence: ground = .corroboratedFeet
                case .body: ground = .plantedFeet
                }
                let body: CountingPolicy.BodyContact
                switch self {
                case .body: body = after ? .clearHandsV2 : .headKneeFoot
                case .ground, .groundContinuity: body = .clearHandsV2
                case .footMotion: body = after ? .movingFootV3 : .clearHandsV2
                case .poseConfidence: body = after ? .observedJointContinuityV5 : .poseContinuityV4
                case .contactTiming: body = after ? .timedFootMotionV6 : .observedJointContinuityV5
                case .legMotion: body = after ? .observedLegMotionV7 : .timedFootMotionV6
                case .legRouting: body = after ? .observedLegMotionV8 : .observedLegMotionV7
                case .temporalEvidence: body = after ? .temporalEvidenceV9 : .observedLegMotionV8
                case .completedRise: body = .temporalEvidenceV9
                case .pixelFoot: body = after ? .trackedFootV10 : .temporalEvidenceV9
                case .observedImpact: body = after ? .observedImpactV11 : .temporalEvidenceV9
                case .independentLeg: body = after ? .independentLegV12 : .observedImpactV11
                case .ballAssociation: body = .independentLegV12
                case .legRebound: body = after ? .legReboundV13 : .independentLegV12
                case .trajectoryTiming, .selectedPose: body = .legReboundV13
                case .raisedFoot: body = after ? .raisedFootV14 : .legReboundV13
                case .footEvidence: body = after ? .footEvidenceV15 : .raisedFootV14
                case .handling: body = .poseContinuityV4
                case .poseContinuity: body = after ? .poseContinuityV4 : .movingFootV3
                }
                return .init(handling: (self == .handling && after) || self == .poseConfidence || self == .contactTiming || self == .legMotion || self == .legRouting || self == .temporalEvidence || self == .completedRise || self == .pixelFoot || self == .observedImpact || self == .independentLeg || self == .ballAssociation || self == .legRebound || self == .trajectoryTiming || self == .selectedPose || self == .raisedFoot || self == .footEvidence ? .sustainedGripV1 : .disabled, verifiesContacts: true, body: body, ground: ground)
            }
        }
        struct Clip: Decodable {
            let id, video, trace: String
            /// Reuse an already staged, digest-checked original in Documents.
            let documentsVideo: Bool?
        }
        let clips: [Clip]
        let comparison: Comparison?
        /// Resume an interrupted comparison when its baseline is already saved.
        let afterOnly: Bool?
        let poseAuditFrames: [Int]?
    }
    @MainActor static func run(folderName: String) async {
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        let folder = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: folderName).lastPathComponent)
        let status = folder.appendingPathComponent("status.txt")
        do {
            try Data("RUNNING".utf8).write(to: status, options: .atomic)
            try await Task.detached(priority: .userInitiated) {
                let config = try JSONDecoder().decode(Configuration.self,
                    from: Data(contentsOf: folder.appendingPathComponent("config.json")))
                for clip in config.clips {
                    guard [clip.id, clip.video, clip.trace].allSatisfy({
                        !$0.isEmpty && $0 == URL(fileURLWithPath: $0).lastPathComponent && $0 != "." && $0 != ".."
                    }) else { throw failure("Invalid clip name") }
                    let archive = try PropertyListDecoder().decode(CounterTraceArchive.self,
                        from: Data(contentsOf: folder.appendingPathComponent(clip.trace)))
                    _ = try archive.trace.replay()
                    let video = (clip.documentsVideo == true ? URL.documentsDirectory : folder).appendingPathComponent(clip.video)
                    guard try SessionAnalysisStore.sourceDigest(video) == archive.sourceDigest else {
                        throw failure("Video and trace do not match")
                    }
                    for after in (config.afterOnly == true ? [true] : [false, true]) {
                        let policy = (config.comparison ?? .body).policy(after: after)
                        var counterConfig = archive.trace.config
                        if config.comparison == .completedRise {
                            counterConfig.completesRiseWhileSlowing = after
                        }
                        if config.comparison == .pixelFoot { counterConfig.completesRiseWhileSlowing = true }
                        if config.comparison == .observedImpact {
                            counterConfig.preservesFallingArcAcrossShortGap = after
                        }
                        if config.comparison == .independentLeg || config.comparison == .ballAssociation || config.comparison == .legRebound || config.comparison == .trajectoryTiming {
                            counterConfig.completesRiseWhileSlowing = true
                            counterConfig.preservesFallingArcAcrossShortGap = true
                        }
                        if config.comparison == .trajectoryTiming { counterConfig.timeAwareTrajectory = after }
                        if config.comparison == .raisedFoot { counterConfig.stabilizesPlayerGround = after }
                        let label = clip.id + (after ? " after" : " before")
                        try Data("RUNNING \(label)".utf8).write(to: status, options: .atomic)
                        // The rebound comparison keeps current RF association identical in both passes.
                        let result = try await replay(video: video, archive: archive, policy: policy, counterConfig: counterConfig,
                                                      status: status, label: label, requiresGroundHeightEvidence: config.comparison == .footEvidence && after, selectedPoseRecovery: config.comparison == .selectedPose && after, poseAuditFrames: Set(config.poseAuditFrames ?? []),
                                                      associateBall: ((config.comparison == .ballAssociation && after) || config.comparison == .legRebound || config.comparison == .trajectoryTiming) && RFSmallModel.allCases.contains { archive.pipelineSignature.contains($0.rawValue) })
                        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                        try encoder.encode(result.trace).write(to: folder.appendingPathComponent(
                            clip.id + (after ? "-after.plist" : "-before.plist")), options: .atomic)
                        try result.recoveryMetrics.write(to: folder.appendingPathComponent(clip.id + (after ? "-after-recovery.json" : "-before-recovery.json")),options: .atomic)
                        try result.evidence.write(to: folder.appendingPathComponent(
                            clip.id + (after ? "-after-evidence.json" : "-before-evidence.json")), options: .atomic)
                        try result.pixelTracks.write(to: folder.appendingPathComponent(clip.id + (after ? "-after-pixel-tracks.json" : "-before-pixel-tracks.json")),options: .atomic)
                        try result.poseAudit.write(to: folder.appendingPathComponent(clip.id + "-pose-audit.json"),options: .atomic)
                        try result.groundEvidence.write(to: folder.appendingPathComponent(
                            clip.id + (after ? "-after-ground.json" : "-before-ground.json")), options: .atomic)
                    }
                }
            }.value
            try Data("DONE".utf8).write(to: status, options: .atomic)
        } catch {
            try? Data("FAILED: \(error)".utf8).write(to: status, options: .atomic)
        }
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: message, code: 1) }

    private struct Result { let trace: CounterTrace; let evidence, groundEvidence, poseAudit, pixelTracks, recoveryMetrics: Data }

    private static func replay(video: URL, archive: CounterTraceArchive, policy: CountingPolicy, counterConfig: CounterConfig,
                               status: URL, label: String, requiresGroundHeightEvidence: Bool, selectedPoseRecovery: Bool, poseAuditFrames: Set<Int>, associateBall: Bool) async throws -> Result {
        let asset = AVURLAsset(url: video)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output: AVAssetReaderOutput
        if archive.mode == .file {
            // Imported traces use the composition clock and transformed pixels,
            // which need not have the original track's frame numbering.
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            composed.videoComposition = try await EffectVideoGeometry.composition(
                track: track, duration: asset.load(.duration), shortEdge: 720)
            output = composed
        } else {
            output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        }
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let observations = ContactObservationStore()
        let verifier = JugglingContactVerifier(observations: observations); verifier.warmUp()
        verifier.usesSelectedPoseRecovery = selectedPoseRecovery
        verifier.requiresGroundHeightEvidence = requiresGroundHeightEvidence
        var poseAudit: [[String: Any]] = []
        var evidence: [[String: Any]] = []
        var pixelTracks: [[String: Any]] = []
        verifier.onPixelTrack = { frame, track, time, milliseconds in
            let data = try! JSONEncoder().encode(track)
            pixelTracks.append(["frame":frame,"contactMs":time as Any? ?? NSNull(),"milliseconds":milliseconds,"track":try! JSONSerialization.jsonObject(with:data)])
        }
        verifier.onContactEvidence = { frame, contactMs, samples in
            evidence.append(["frame": frame, "contactMs": contactMs, "samples": samples.map { sample -> [String: Any] in
                let s = sample.pose
                return ["timestampMs": s.timestampMs, "ball": [s.ball.x, s.ball.y, s.width, s.height, s.confidence, s.imageAspect],
                    "joints": Dictionary(uniqueKeysWithValues: s.joints.map { ($0.key.rawValue, [$0.value.x, $0.value.y]) }),
                    "landmarks": Dictionary(uniqueKeysWithValues: sample.landmarks.map { ($0.key.rawValue, [$0.value.x,$0.value.y,$0.value.confidence]) }),
                    "ankles": Dictionary(uniqueKeysWithValues: sample.ankles.map { ($0.key.rawValue, [$0.value.x, $0.value.y, $0.value.confidence]) })]
            }])
        }
        verifier.onPoseRecoveryEvidence = { frame,contactMs,samples in
            evidence.append(["frame": frame,"contactMs": contactMs,"kind": "selectedPoseRecovery",
                "samples": samples.map { sample -> [String: Any] in
                    let p = sample.pose
                    return ["timestampMs": p.timestampMs,"ball": [p.ball.x,p.ball.y,p.width,p.height,p.confidence,p.imageAspect],
                        "landmarks": Dictionary(uniqueKeysWithValues: sample.landmarks.map { ($0.key.rawValue,[$0.value.x,$0.value.y,$0.value.confidence]) })]
                }])
        }
        let counter = ContactCounterFactory.make(verifier: verifier, policy: policy, config: counterConfig)
        var association = BallPlausibility(policy: .rfDetrAssociationV1)
        guard reader.startReading() else { throw reader.error ?? failure("Reader failed") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var sourceIndex = 0, operation = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                defer { sourceIndex += 1 }
                guard operation < archive.trace.operations.count,
                      let input = archive.trace.operations[operation].input,
                      input.sourceFrameIndex == sourceIndex else { return }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard abs(time-(Double(input.timestampMs)/1000-archive.timeOriginSeconds)) < 0.002,
                      let pixels = CMSampleBufferGetImageBuffer(sample) else { throw failure("Frame mismatch") }
                var ball = input.ball.map { Detection(score: $0.confidence, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                if associateBall, let detected = ball {
                    ball = association.accept(detected, frame: input.frameIndex, timestampMs: input.timestampMs)
                }
                if !input.reliable { verifier.discardFrames() }
                else { verifier.store(pixels, frameIndex: input.frameIndex, timestampMs: input.timestampMs,
                                      ball: ball, orientLandscapeAsPortrait: false, player: input.player) }
                if poseAuditFrames.contains(input.frameIndex),
                   let frame = observations.frames.first(where: { $0.index == input.frameIndex }) {
                    poseAudit.append(try ContactPoseAudit.inspect(frame, source: pixels))
                }
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: ball == nil ? nil : input.ball,
                    person: input.person, cameraOffsetY: input.cameraOffsetY, reliable: input.reliable,
                    sourceFrameIndex: sourceIndex, player: input.player)
                operation += 1
                if operation.isMultiple(of: 150) {
                    try Data("RUNNING \(label) \(operation)/\(archive.trace.operations.count)".utf8)
                        .write(to: status, options: .atomic)
                }
            }
        }
        guard reader.status == .completed, operation == archive.trace.operations.count-1 else {
            throw reader.error ?? failure("Incomplete replay")
        }
        counter.flush()
        guard verifier.lastError == nil, let result = counter.traceSnapshot(),
              verifier.peakBufferedFrames <= ContactFrameWindow.maximumBufferedFrames else { throw failure(verifier.lastError ?? "Invalid contact buffer") }
        _ = try result.replay()
        let groundEvidence = Dictionary(uniqueKeysWithValues: result.decisions.compactMap { decision in
            decision.value.groundEvidence.map { (decision.value.frameIndex, $0) }
        })
        return Result(trace: result, evidence: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                      groundEvidence: try JSONEncoder().encode(groundEvidence),
                      poseAudit: try JSONSerialization.data(withJSONObject: poseAudit,options: [.sortedKeys]),
                      pixelTracks: try JSONSerialization.data(withJSONObject: pixelTracks,options: [.sortedKeys]),
                      recoveryMetrics: try JSONSerialization.data(withJSONObject: verifier.poseRecoveryMetrics,options: [.sortedKeys]))
    }
}
#endif
