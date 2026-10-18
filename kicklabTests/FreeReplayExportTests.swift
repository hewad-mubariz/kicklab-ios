import AVFoundation
import UIKit
import Vision
import XCTest
@testable import kicklab

final class FreeReplayExportTests: XCTestCase {
    func testDirectReaderRequiresUprightUnscaledFullFrameSDR() throws {
        let size = CGSize(width: 720, height: 1280)
        func format(transfer: String = AVVideoTransferFunction_ITU_R_709_2, aperture: Bool = false) throws -> CMFormatDescription {
            var description: CMVideoFormatDescription?
            var extensions: [String: Any] = [
                kCMFormatDescriptionExtension_ColorPrimaries as String: AVVideoColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction as String: transfer,
                kCMFormatDescriptionExtension_YCbCrMatrix as String: AVVideoYCbCrMatrix_ITU_R_709_2]
            if aperture {
                extensions[kCMFormatDescriptionExtension_CleanAperture as String] = [
                    kCMFormatDescriptionKey_CleanApertureWidth as String: 700,
                    kCMFormatDescriptionKey_CleanApertureHeight as String: 1280,
                    kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String: 0,
                    kCMFormatDescriptionKey_CleanApertureVerticalOffset as String: 0]
            }
            XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
                width: 720, height: 1280, extensions: extensions as CFDictionary, formatDescriptionOut: &description), noErr)
            return try XCTUnwrap(description)
        }
        let sdr = try format()
        XCTAssertTrue(BallStyleBurnIn.canReadDirectly(naturalSize: size, outputSize: size, transform: .identity, formats: [sdr]))
        XCTAssertFalse(BallStyleBurnIn.canReadDirectly(naturalSize: size, outputSize: size,
            transform: CGAffineTransform(rotationAngle: .pi / 2), formats: [sdr]))
        XCTAssertFalse(BallStyleBurnIn.canReadDirectly(naturalSize: size, outputSize: CGSize(width: 360, height: 640),
            transform: .identity, formats: [sdr]))
        XCTAssertFalse(BallStyleBurnIn.canReadDirectly(naturalSize: size, outputSize: size, transform: .identity, formats: []))
        XCTAssertFalse(BallStyleBurnIn.canReadDirectly(naturalSize: size, outputSize: size, transform: .identity,
            formats: [try format(transfer: AVVideoTransferFunction_ITU_R_2100_HLG)]))
        XCTAssertFalse(BallStyleBurnIn.canReadDirectly(naturalSize: size, outputSize: size, transform: .identity,
            formats: [try format(aperture: true)]))
    }

    func testBitrateUsesActualOutputSizeAndPixelCopyPreservesEveryChannel() throws {
        XCTAssertEqual(BallStyleBurnIn.bitrate(for: CGSize(width: 720, height: 1280)), 7_000_000)
        XCTAssertEqual(BallStyleBurnIn.bitrate(for: CGSize(width: 1920, height: 1080)), 14_000_000)
        func buffer(alignment: Int, width: Int = 17) throws -> CVPixelBuffer {
            var value: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, width, 13, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferBytesPerRowAlignmentKey: alignment] as CFDictionary, &value), kCVReturnSuccess)
            return try XCTUnwrap(value)
        }
        let source = try buffer(alignment: 64), target = try buffer(alignment: 256)
        CVPixelBufferLockBaseAddress(source, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<13 { for col in 0..<17 * 4 {
            bytes[row * CVPixelBufferGetBytesPerRow(source) + col] = UInt8((row * 37 + col) % 256)
        } }
        CVPixelBufferUnlockBaseAddress(source, [])
        XCTAssertTrue(BallStyleBurnIn.copyBGRA(source, to: target))
        CVPixelBufferLockBaseAddress(target, .readOnly)
        let copied = try XCTUnwrap(CVPixelBufferGetBaseAddress(target)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<13 { for col in 0..<17 * 4 {
            XCTAssertEqual(copied[row * CVPixelBufferGetBytesPerRow(target) + col], UInt8((row * 37 + col) % 256))
        } }
        CVPixelBufferUnlockBaseAddress(target, .readOnly)
        XCTAssertFalse(BallStyleBurnIn.copyBGRA(source, to: try buffer(alignment: 64, width: 18)))
    }

    /// Decode actual free exports: verifies upright, optional overlays without any ball effect or model pass.
    func testFreeTimerAndCounterAreEncodedIndependentlyUsingVideoTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let size = CGSize(width: 720, height: 1280)
        let movie = try PreviewMovie(url: source, size: size, frameRate: 5)
        let pixels = try movie.buffer()
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 720, height: 1280,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 0.28, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<12 { try await movie.append(pixels, time: CMTime(value: Int64(frame), timescale: 5)) }
        try await movie.finish(duration: CMTime(value: 12, timescale: 5))
        let timeline = ExportCounterTimeline(touches: [.init(index: 12, time: 0.4, x: 0.5, y: 0.5)], total: 12)

        for counterEnabled in [true, false] {
            for timerEnabled in [true, false] {
                var settings = ExportOverlaySettings()
                settings.counter.enabled = counterEnabled
                settings.counter.style = .jelly // A saved Pro choice must resolve to the free Normal style.
                settings.showTimer = timerEnabled
                settings.graph.enabled = true
                let look = JugglingReplayLook(edit: .init(style: .fire, ballSkin: .chrome),
                    overlays: settings, showGraph: true).allowed(isPro: false)
                XCTAssertFalse(look.requiresPro)
                let output = try await BallStyleBurnIn.render(source: source, track: [], style: look.edit.style,
                    skin: look.edit.ballSkin, intensity: 0, shortEdge: 720, counter: timeline,
                    overlays: look.overlays, preserveFrameTimes: !counterEnabled)
                defer { try? FileManager.default.removeItem(at: output) }
                let asset = AVURLAsset(url: output)
                let duration = try await asset.load(.duration)
                XCTAssertEqual(duration.seconds, 2.4, accuracy: 0.04)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let frame = try await generator.image(at: CMTime(value: 6, timescale: 5)).image
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: frame).perform([request])
                let words = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
                XCTAssertEqual(words.contains("TOUCHES"), counterEnabled, "Encoded text: \(words)")
                XCTAssertEqual(words.contains("00:01"), timerEnabled, "Encoded text: \(words)")
                let attachment = XCTAttachment(image: UIImage(cgImage: frame))
                attachment.name = "Free export counter-\(counterEnabled) timer-\(timerEnabled)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}
