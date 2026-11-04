import AVFoundation
import CryptoKit
import Foundation
import simd
import UIKit
import XCTest
@testable import kicklab

@MainActor
final class BallSurfacePipelinePhoneTests: XCTestCase {
    struct Frame: Encodable {
        let time: Double
        let orientation: [Float]
        let accepted: Bool, visible: Bool
        let white: [Float]?
    }
    struct Output: Encodable { let frames: [Frame]; let exposure: Double? }
    struct Run: Encodable {
        let pipelined: Bool
        let seconds: Double
        let thermalBefore: Int, thermalAfter: Int
        let peakMemoryMiB: Double
        let digest: String
    }
    private func memoryMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
    func testPipelinedSpinComparison() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phone timing only")
        #endif
        let folder = URL.documentsDirectory.appending(path: "exact-clip-check")
        let file = folder.appending(path: "prepared-visual.plist")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path))
        let frames = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf: file))
        XCTAssertTrue(StoredFrame.validated(frames))
        let track = BallEffectTrack(frames: frames.map(\.frame)), source = folder.appending(path: "clip.mov")
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        var runs = [Run](), reference: Data?
        for pipelined in [false, true, true, false] {
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            var peak = memoryMiB()
            let sampler = Task {
                while !Task.isCancelled {
                    peak = max(peak, memoryMiB())
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { sampler.cancel() }
            let start = ProcessInfo.processInfo.systemUptime
            let motion = try await VideoWorkExecution.detached {
                if pipelined { return try await BallSurfacePipelineProbe.analyze(source: source, track: track) }
                return try await BallSurfaceTimeline.analyze(source: source, track: track)
            }.value
            let seconds = ProcessInfo.processInfo.systemUptime - start
            sampler.cancel()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let result = Output(frames: motion.entries.map {
                Frame(time: $0.time, orientation: [$0.orientation.vector.x, $0.orientation.vector.y,
                    $0.orientation.vector.z, $0.orientation.vector.w], accepted: $0.accepted,
                    visible: $0.visible, white: $0.white.map { [$0.x, $0.y, $0.z] })
            }, exposure: motion.photographicExposure)
            let bytes = try encoder.encode(result)
            if let reference { XCTAssertEqual(bytes, reference, "Pipelining changed spin or lighting") }
            else { reference = bytes }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            runs.append(.init(pipelined: pipelined, seconds: seconds, thermalBefore: thermal,
                thermalAfter: ProcessInfo.processInfo.thermalState.rawValue, peakMemoryMiB: peak, digest: digest))
            try encoder.encode(runs).write(to: folder.appending(path: "spin-pipeline-comparison.json"), options: .atomic)
        }
    }
}

nonisolated enum BallSurfacePipelineProbe {
    static let initial = BallSurfaceTimeline.initial
    /// Experiment only: at most one future frame; sole ownership of decoder.
    private struct SurfaceFrame: @unchecked Sendable {
        let time: Double
        var pixels: CVPixelBuffer?
        var fitted: BallReplacementFootprint?
        var prepared: BallSurfaceMotion.Prepared?
        var white: SIMD3<Float>?
    }
    private final class SurfaceFrameCursor: @unchecked Sendable {
        let output: AVAssetReaderVideoCompositionOutput
        let track: BallEffectTrack
        init(output: AVAssetReaderVideoCompositionOutput, track: BallEffectTrack) {
            self.output = output; self.track = track
        }
        func next() async throws -> SurfaceFrame? {
            try await VideoWorkExecution.checkpoint(requiresGPU: false)
            return autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else { return nil }
                let time = buffer.presentationTimeStamp.seconds
                guard time.isFinite, let pixels = CMSampleBufferGetImageBuffer(buffer),
                      let sample = track.replacementGuide(at: time), sample.confidence >= 0.3,
                      let fitted = BallReplacementFootprint.fit(pixels: pixels, sample: sample),
                      let patch = BallSurfaceMotion.patch(pixels: pixels, center: fitted.center,
                          radius: fitted.radii.reduce(0,+)/Double(fitted.radii.count)) else { return SurfaceFrame(time: time) }
                return SurfaceFrame(time: time, pixels: pixels, fitted: fitted,
                    prepared: BallSurfaceMotion.Prepared(patch),
                    white: BallSurfaceTimeline.white(pixels: pixels, center: fitted.center,
                        radius: fitted.radii.reduce(0,+)/Double(fitted.radii.count)))
            }
        }
    }

    static func analyze(source: URL, track: BallEffectTrack) async throws -> BallSurfaceTimeline {
        let scoped=source.startAccessingSecurityScopedResource()
        defer {if scoped {source.stopAccessingSecurityScopedResource()}}
        let start=ProcessInfo.processInfo.systemUptime
        var timing = BallPreparationTiming(enabled: BallPreparationTiming.enabledForBuild)
        let asset=AVURLAsset(url:source)
        guard let video=try await asset.loadTracks(withMediaType:.video).first else {
            throw NSError(domain:"KickLab.SurfaceMotion",code:1,userInfo:[NSLocalizedDescriptionKey:"No video track."])
        }
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        // Analyze the source cadence. Do not throw away the 120 fps frames that
        // disambiguate fast backspin; output video can still be 30/60 fps.
        let duration = try await asset.load(.duration)
        let composition = try await EffectVideoGeometry.composition(track:video,duration:duration,shortEdge:720)
        output.videoComposition=composition
        output.alwaysCopiesSampleData=false;reader.add(output)
        guard reader.startReading() else {throw reader.error!}
        defer {if reader.status == .reading {reader.cancelReading()}}
        var entries=[BallSurfaceTimeline.Entry](),pose=initial,previous:BallSurfaceMotion.Prepared?,previousTime:Double?
        var exposure = BallExposureCalibration(duration: duration.seconds, frameDuration: composition.frameDuration.seconds)
        timing.record(.setup, since: start)
        let cursor = SurfaceFrameCursor(output: output, track: track)
        var next = try await cursor.next()
        while let frame = next {
            try await VideoWorkExecution.checkpoint(requiresGPU: false)
            async let following = cursor.next()
            timing.decodedFrames += 1
            let time = frame.time
            if let pixels = frame.pixels, let fitted = frame.fitted, let current = frame.prepared {
                timing.fittedFrames += 1
                var accepted = false
                if exposure.shouldMeasure(at: time) {
                    let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                    if let velocity = track.velocity(at: time, size: size),
                       let blur = timing.measure(.exposure, { BallReplacementMotionBlur.measured(pixels: pixels, body: fitted,
                            suggested: track.smear(at: time, size: size)) }) {
                        exposure.observe(time: time, smear: blur, velocity: velocity)
                    }
                }
                if let previous, let previousTime, time > previousTime, time - previousTime < 0.06 {
                    timing.rotationPairs += 1
                    let result = timing.measure(.rotation, { BallSurfaceMotion.estimate(previous: previous, current: current) })
                    if result.accepted {
                        accepted = true; timing.acceptedPairs += 1
                        let vector = SIMD3<Float>(result.rotation), angle = simd_length(vector)
                        if angle > 1e-7 { pose = simd_normalize(simd_quatf(angle: angle, axis: vector/angle)*pose) }
                    }
                }
                entries.append(BallSurfaceTimeline.Entry(time: time, orientation: pose, accepted: accepted, white: frame.white))
                previous = current; previousTime = time
            } else {
                previous = nil; previousTime = nil
                entries.append(BallSurfaceTimeline.Entry(time: time, orientation: pose, accepted: false, visible: false))
            }
            next = try await following
        }
        guard reader.status == .completed else {throw reader.error ?? NSError(domain:"KickLab.SurfaceMotion",code:2)}
        timing.totalSeconds = ProcessInfo.processInfo.systemUptime-start
        if PreparationPerformance.enabled {
            var metrics = timing.stages.mapValues(\.seconds)
            metrics["elapsed_s"] = timing.totalSeconds
            metrics["decoded_frames"] = Double(timing.decodedFrames)
            metrics["rotation_pairs"] = Double(timing.rotationPairs)
            metrics["accepted_pairs"] = Double(timing.acceptedPairs)
            PreparationPerformance.record("ball_motion", metrics)
        }
        return BallSurfaceTimeline(entries:entries,elapsed:timing.totalSeconds,photographicExposure:exposure.estimate,
                    preparationTiming: timing.enabled ? timing : nil)
    }
}
