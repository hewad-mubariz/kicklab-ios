import AVFoundation
import XCTest
@testable import kicklab

/// Renders the launch demo with one effect through the app's own engine, exactly as the Effects Lab
/// footage renderer does, so the result can be compared with the video the user accepted there.
/// Set LAB_PARITY_EFFECT (a BallStyle raw value) and LAB_PARITY_OUT (a folder) to run it.
final class LabEffectParityTests: XCTestCase {
    private struct Point: Decodable {
        let time, x, y, width, height, score: Double
        let personX, personY, personWidth, personHeight: Double?
    }
    private struct Touch: Decodable { let time: Double }
    private struct Analysis: Decodable { let track: [Point]; let touchesMarked: [Touch] }

    private static let demo = URL(fileURLWithPath: "/Users/hewadmubariz/Desktop/projects/kicklab/artifacts/launch-demo-20261011")

    private func track(_ url: URL? = nil) throws -> BallEffectTrack {
        let url = url ?? Self.demo.appending(path: "analysis-native.json")
        let analysis = try JSONDecoder().decode(Analysis.self, from: Data(contentsOf: url))
        return BallEffectTrack(frames: analysis.track.map { p in
            let person: PersonBox? = if let x = p.personX, let y = p.personY, let w = p.personWidth, let h = p.personHeight {
                PersonBox(x: x, y: y, width: w, height: h)
            } else { nil }
            return RecordedFrame(time: p.time, x: p.x, y: p.y, width: p.width, height: p.height, score: p.score,
                                 smoothedX: p.x, smoothedY: p.y, vy: 0, motion: .unknown, detected: p.score >= 0.05, person: person)
        }, touchTimes: analysis.touchesMarked.map(\.time))
    }

    /// On the phone: 10 seconds of the launch demo at export size for each new effect, timing the
    /// scene (CPU) and the draw (GPU) separately. Copy the demo and its track to Documents/lab-check.
    func testNewEffectCostOnThisPhone() async throws {
        let folder = URL.documentsDirectory.appending(path: "lab-check")
        let source = folder.appending(path: "source-1080p120.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Copy the launch demo to Documents/lab-check")
        let track = try track(folder.appending(path: "analysis-native.json"))
        func note(_ key: String, _ value: Any) { print("PHONECHECK \(key) = \(value)") }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : (sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] * 10).rounded() / 10
        }
        var start = ProcessInfo.processInfo.systemUptime
        LiquidFluid.prepareAll()
        note("prepare_liquid_ms", Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
        start = ProcessInfo.processInfo.systemUptime
        WaterCrown.prepareAll()
        note("prepare_water_ms", Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        let engine = try MetalEffectEngine()
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        let target = try XCTUnwrap(made)
        for style in [BallStyle.neon, .galaxy, .liquid, .water, .crystal] {
            let reader = try AVAssetReader(asset: asset)
            let decoded = AVAssetReaderTrackOutput(track: video, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
            decoded.alwaysCopiesSampleData = false
            reader.add(decoded)
            XCTAssertTrue(reader.startReading())
            let edit = SessionEditState(style: style, intensity: 0.7, ballSkin: .original)
            var scene: [Double] = [], draw: [Double] = [], parts = 0
            var held: CMSampleBuffer?, pending = decoded.copyNextSampleBuffer()
            for index in 0..<300 {
                let time = Double(index) / 30
                while let next = pending, next.presentationTimeStamp.seconds <= time + 0.000001 {
                    held = next; pending = decoded.copyNextSampleBuffer()
                }
                let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(try XCTUnwrap(held ?? pending)))
                CVPixelBufferLockBaseAddress(pixels, .readOnly); CVPixelBufferLockBaseAddress(target, [])
                let from = CVPixelBufferGetBaseAddress(pixels)!, to = CVPixelBufferGetBaseAddress(target)!
                let fromRow = CVPixelBufferGetBytesPerRow(pixels), toRow = CVPixelBufferGetBytesPerRow(target)
                for y in 0..<Int(size.height) { memcpy(to + y * toRow, from + y * fromRow, min(fromRow, toRow)) }
                CVPixelBufferUnlockBaseAddress(pixels, .readOnly); CVPixelBufferUnlockBaseAddress(target, [])
                let a = ProcessInfo.processInfo.systemUptime
                let frame = EffectFrame.video(size: size, sourceSize: size, edit: edit, track: track, time: time)
                let b = ProcessInfo.processInfo.systemUptime
                try engine.composite(frame, pixelBuffer: target)
                let c = ProcessInfo.processInfo.systemUptime
                scene.append((b - a) * 1000); draw.append((c - b) * 1000)
                parts = max(parts, frame.liquid?.parts.count ?? frame.water?.parts.count ?? frame.crystal?.objects.count ?? 0)
            }
            reader.cancelReading()
            note("\(style.rawValue)_scene_ms_p50_p95", "\(percentile(scene, 0.5)) / \(percentile(scene, 0.95))")
            note("\(style.rawValue)_draw_ms_p50_p95", "\(percentile(draw, 0.5)) / \(percentile(draw, 0.95))")
            note("\(style.rawValue)_max_parts", parts)
            note("\(style.rawValue)_thermal_after", ProcessInfo.processInfo.thermalState.rawValue)
        }
    }

    /// The picker icons of the lab effects, written as PNGs next to the renders.
    func testLabEffectIcons() throws {
        guard let folder = ProcessInfo.processInfo.environment["LAB_PARITY_OUT"] else { throw XCTSkip("Set LAB_PARITY_OUT") }
        let engine = try MetalEffectEngine()
        let ball = BallSkinSphereRenderer.image(skin: .classic, time: 0)
        for style in [BallStyle.neon, .galaxy, .liquid, .water, .crystal] {
            for (suffix, print) in [("", ball), ("-effect", nil)] {
                let icon = try XCTUnwrap(EffectIconRenderer.image(shaderStyle: style.shaderID, height: 240, ball: print, engine: engine))
                let url = URL(fileURLWithPath: folder).appending(path: "icon-\(style.rawValue)\(suffix).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, icon, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }

    func testRenderLaunchDemoWithEffect() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["LAB_PARITY_EFFECT"], let folder = environment["LAB_PARITY_OUT"],
              let style = BallStyle(rawValue: name) else { throw XCTSkip("Set LAB_PARITY_EFFECT and LAB_PARITY_OUT") }
        let intensity = environment["LAB_PARITY_INTENSITY"].flatMap(Double.init) ?? 0.7
        let source = Self.demo.appending(path: "v2/source-1080p120.mp4")
        let output = URL(fileURLWithPath: folder).appending(path: "\(name)-app.mp4")
        try? FileManager.default.removeItem(at: output)
        let track = try track()

        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let duration = try await video.load(.timeRange).duration.seconds
        let size = try await video.load(.naturalSize)
        let fps = 30.0
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        decoded.alwaysCopiesSampleData = false
        reader.add(decoded)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoExpectedSourceFrameRateKey: Int(fps)],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 60_000
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let engine = try MetalEffectEngine()
        let edit = SessionEditState(style: style, intensity: intensity, ballSkin: .original)
        LiquidFluid.prepareAll(); WaterCrown.prepareAll()
        var held: CMSampleBuffer?, pending = decoded.copyNextSampleBuffer()
        for index in 0..<Int(ceil(duration * fps)) {
            let time = Double(index) / fps
            while let next = pending, next.presentationTimeStamp.seconds <= time + 0.000001 {
                held = next; pending = decoded.copyNextSampleBuffer()
            }
            let sample = try XCTUnwrap(held ?? pending)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            try autoreleasepool {
                let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                let pool = try XCTUnwrap(adaptor.pixelBufferPool)
                var made: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                let target = try XCTUnwrap(made)
                CVPixelBufferLockBaseAddress(pixels, .readOnly); CVPixelBufferLockBaseAddress(target, [])
                let from = CVPixelBufferGetBaseAddress(pixels)!, to = CVPixelBufferGetBaseAddress(target)!
                let fromRow = CVPixelBufferGetBytesPerRow(pixels), toRow = CVPixelBufferGetBytesPerRow(target)
                for y in 0..<Int(size.height) { memcpy(to + y * toRow, from + y * fromRow, min(fromRow, toRow)) }
                CVPixelBufferUnlockBaseAddress(pixels, .readOnly); CVPixelBufferUnlockBaseAddress(target, [])
                CVBufferPropagateAttachments(pixels, target)
                let frame = EffectFrame.video(size: size, sourceSize: size, edit: edit, track: track, time: time)
                try engine.composite(frame, pixelBuffer: target)
                XCTAssertTrue(adaptor.append(target, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60_000)))
            }
        }
        if reader.status == .reading { reader.cancelReading() }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
