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

    private func track() throws -> BallEffectTrack {
        let analysis = try JSONDecoder().decode(Analysis.self, from: Data(contentsOf: Self.demo.appending(path: "analysis-native.json")))
        return BallEffectTrack(frames: analysis.track.map { p in
            let person: PersonBox? = if let x = p.personX, let y = p.personY, let w = p.personWidth, let h = p.personHeight {
                PersonBox(x: x, y: y, width: w, height: h)
            } else { nil }
            return RecordedFrame(time: p.time, x: p.x, y: p.y, width: p.width, height: p.height, score: p.score,
                                 smoothedX: p.x, smoothedY: p.y, vy: 0, motion: .unknown, detected: p.score >= 0.05, person: person)
        }, touchTimes: analysis.touchesMarked.map(\.time))
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
