import AVFoundation
import UIKit
import Vision
import XCTest
@testable import kicklab

final class BallDistanceExportTests: XCTestCase {
    /// Exercise the actual encoder: the saved distance must be readable and upright,
    /// while an ordinary effects-only video must remain free of metric annotations.
    func testSavedDistanceIsReadableInExportAndAbsentFromEffectsOnlyExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let movie = try PreviewMovie(url: source, size: CGSize(width: 720, height: 1280), frameRate: 30)
        let pixels = try movie.buffer()
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 720, height: 1280,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 0.28, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 1280))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<6 { try await movie.append(pixels, time: CMTime(value: Int64(frame), timescale: 30)) }
        try await movie.finish(duration: CMTime(value: 6, timescale: 30))
        let distance = BallDistanceTimeline(samples: [
            .init(time: 0, distanceM: 0, status: .tracking),
            .init(time: 0.1, distanceM: 1.2, status: .tracking)])
        for timeline in [distance, nil] {
            let output = try await BallStyleBurnIn.render(source: source, track: [], style: .none,
                intensity: 0, shortEdge: 720, distanceTimeline: timeline)
            defer { try? FileManager.default.removeItem(at: output) }
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(CMTimeGetSeconds(duration), 0.2, accuracy: 0.04)
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(value: 4, timescale: 30)).image
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: frame).perform([request])
            let words = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            if timeline != nil {
                XCTAssertTrue(words.contains("DISTANCE"), words)
                XCTAssertTrue(words.contains("1.20"), "Distance text must be upright and readable: \(words)")
                let attachment = XCTAttachment(image: UIImage(cgImage: frame))
                attachment.name = "Calibrated distance - encoded video frame"; attachment.lifetime = .keepAlways
                add(attachment)
            } else {
                XCTAssertFalse(words.contains("DISTANCE")); XCTAssertFalse(words.contains("1.20"))
            }
        }
    }
}
