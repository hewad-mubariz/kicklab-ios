import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import kicklab

/// The saved video draws each run's own effect.
struct LookExportTests {
    private let size = CGSize(width: 360, height: 640)

    /// A plain grey clip with the ball tracked at the centre throughout.
    private func clip(seconds: Double) async throws -> (url: URL, frames: [RecordedFrame]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("looks-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let count = Int(seconds * 30)
        for index in 0..<count {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixels: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixels)
            CVPixelBufferLockBaseAddress(pixels!, [])
            memset(CVPixelBufferGetBaseAddress(pixels!), 72, CVPixelBufferGetBytesPerRow(pixels!) * Int(size.height))
            CVPixelBufferUnlockBaseAddress(pixels!, [])
            #expect(adaptor.append(pixels!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: 30))
        await writer.finishWriting()
        let frames = (0..<count).map { index in
            RecordedFrame(time: Double(index) / 30, x: 0.5, y: 0.5, width: 0.1, height: 0.05625, score: 0.9,
                          smoothedX: 0.5, smoothedY: 0.5, vy: 0, motion: .unknown, detected: true, person: nil)
        }
        return (url, frames)
    }

    /// How far the centre of the frame strays from flat grey.
    private func energy(_ url: URL, at seconds: Double) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Encoding shifts the grey, so compare the centre with the frame's own untouched corner.
        var reference = [0.0, 0.0, 0.0], corner = 0.0
        for y in 4..<44 { for x in 4..<44 {
            let i = (y * width + x) * 4
            for c in 0..<3 { reference[c] += Double(pixels[i + c]) }
            corner += 1
        } }
        reference = reference.map { $0 / corner }
        var total = 0.0, samples = 0.0
        for y in (height / 2 - 90)..<(height / 2 + 90) {
            for x in (width / 2 - 90)..<(width / 2 + 90) {
                let i = (y * width + x) * 4
                for c in 0..<3 { total += abs(Double(pixels[i + c]) - reference[c]) }
                samples += 1
            }
        }
        return total / samples
    }

    @Test func eachRunDrawsItsOwnEffectInTheSavedVideo() async throws {
        let (source, frames) = try await clip(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        // Fire for the first run; from the second touch on, no effect at all.
        let output = try await BallStyleBurnIn.render(source: source, track: frames, style: .fire, intensity: 1,
            shortEdge: 360, touchTimes: [0.4, 1.0],
            lookChanges: [1: TouchLook(ball: .original, effect: .none)])
        defer { try? FileManager.default.removeItem(at: output) }
        let fire = try await energy(output, at: 0.8)
        let plain = try await energy(output, at: 1.7)
        #expect(fire > 6, "The first run draws fire around the ball: \(fire)")
        #expect(plain < 2, "After the change the footage is plain: \(plain)")
        // And the other way round: nothing first, then an effect.
        let reversed = try await BallStyleBurnIn.render(source: source, track: frames, style: .none, intensity: 1,
            shortEdge: 360, touchTimes: [0.4, 1.0],
            lookChanges: [1: TouchLook(ball: .original, effect: .electric)])
        defer { try? FileManager.default.removeItem(at: reversed) }
        #expect(try await energy(reversed, at: 0.8) < 2)
        #expect(try await energy(reversed, at: 1.7) > 6)
    }
}
