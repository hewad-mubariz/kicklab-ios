import AVFoundation
import UIKit
import Vision
import XCTest
@testable import kicklab

final class MotionGraphExportTests: XCTestCase {
    /// Photos needs this movie-level flag to distinguish full-speed high-FPS video
    /// from slow motion. Check the final file, including the audio remux path.
    func testHighFrameRateGraphExportsRequestNormalPlaybackWithAndWithoutAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "scene-audio", withExtension: "m4a"))
        let audioAsset = AVURLAsset(url: audioURL)
        defer { withExtendedLifetime(audioAsset) {} }
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)

        for fps: Int32 in [120, 240] {
            for includeAudio in [false, true] {
                let silent = folder.appendingPathComponent("silent-\(fps)-\(includeAudio).mp4")
                let source = folder.appendingPathComponent("source-\(fps)-\(includeAudio).mp4")
                let size = CGSize(width: 180, height: 320)
                let movie = try PreviewMovie(url: silent, size: size, frameRate: Double(fps))
                let pixels = try movie.buffer()
                CVPixelBufferLockBaseAddress(pixels, [])
                memset(CVPixelBufferGetBaseAddress(pixels)!, 80, CVPixelBufferGetBytesPerRow(pixels) * 320)
                CVPixelBufferUnlockBaseAddress(pixels, [])
                let frameCount = Int(fps / 2)
                let duration = CMTime(value: Int64(frameCount), timescale: fps)
                for frame in 0..<frameCount {
                    try await movie.append(pixels, time: CMTime(value: Int64(frame), timescale: fps))
                }
                try await movie.finish(duration: duration)
                try await StadiumPreviewPreparer.preserveAudio(silent: silent, destination: source,
                    audio: includeAudio ? audioTracks : [], duration: duration)
                var settings = ExportOverlaySettings()
                settings.counter.enabled = false
                settings.graph.enabled = true
                let output = try await BallStyleBurnIn.render(source: source, track: [], style: .none,
                    intensity: 0, shortEdge: 180, overlays: settings, motionTimeline: MotionStyleSample.timeline)
                defer { try? FileManager.default.removeItem(at: output) }
                let asset = AVURLAsset(url: output)
                let metadata = try await asset.load(.metadata)
                let intent = try XCTUnwrap(metadata.first { $0.identifier == .quickTimeMetadataFullFrameRatePlaybackIntent })
                let value = try await intent.load(.numberValue)
                XCTAssertEqual(value?.intValue, 1, "Full-speed intent must survive audio remuxing")
                let actualDuration = try await asset.load(.duration)
                XCTAssertEqual(actualDuration.seconds, duration.seconds, accuracy: 0.002)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                XCTAssertEqual(audio.count, includeAudio ? audioTracks.count : 0)
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let reader = try AVAssetReader(asset: asset)
                let samples = AVAssetReaderTrackOutput(track: track,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(samples)
                XCTAssertTrue(reader.startReading())
                var timestamps: [Double] = []
                while let sample = samples.copyNextSampleBuffer() {
                    if CMSampleBufferGetImageBuffer(sample) != nil {
                        timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    }
                }
                XCTAssertEqual(reader.status, .completed)
                XCTAssertEqual(timestamps.count, frameCount)
                for (index, stamp) in timestamps.sorted().enumerated() {
                    XCTAssertEqual(stamp, Double(index) / Double(fps), accuracy: 1.0 / 60_000)
                }
            }
        }
    }

    @MainActor
    func testEveryStyleRendersAndFitsPortraitAndLandscape() throws {
        for size in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)] {
            for style in MotionStyle.allCases {
                let rect = ExportMotionGraphRenderer.rect(style: style, in: size)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
                let first = try XCTUnwrap(ExportMotionGraphRenderer.image(style: style,
                    snapshot: MotionStyleSample.timeline.snapshot(at: 2.1, duration: 5.6), size: size))
                let second = try XCTUnwrap(ExportMotionGraphRenderer.image(style: style,
                    snapshot: MotionStyleSample.timeline.snapshot(at: 4.3, duration: 5.6), size: size))
                XCTAssertGreaterThan(first.width, 0)
                XCTAssertNotEqual(UIImage(cgImage: first).pngData(), UIImage(cgImage: second).pngData(),
                                  "\(style) must follow media time")
            }
        }
    }

    /// Decode the real encoder output: catches dropped graphs and upside-down text.
    func testSavedGraphIsUprightAndOptional() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let size = CGSize(width: 720, height: 1280)
        let movie = try PreviewMovie(url: source, size: size, frameRate: 30)
        let pixels = try movie.buffer()
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 720, height: 1280,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 0.28, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<12 { try await movie.append(pixels, time: CMTime(value: Int64(frame), timescale: 30)) }
        try await movie.finish(duration: CMTime(value: 12, timescale: 30))

        for enabled in [true, false] {
            var settings = ExportOverlaySettings()
            settings.counter.enabled = false
            settings.graph.enabled = enabled
            let output = try await BallStyleBurnIn.render(source: source, track: [], style: .none,
                intensity: 0, shortEdge: 720, overlays: settings, motionTimeline: MotionStyleSample.timeline)
            defer { try? FileManager.default.removeItem(at: output) }
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(CMTimeGetSeconds(duration), 0.4, accuracy: 0.04)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: CMTime(value: 8, timescale: 30)).image
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: frame).perform([request])
            let words = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            XCTAssertEqual(words.contains("BALL MOTION"), enabled, "Encoded text: \(words)")
            if enabled {
                let attachment = XCTAttachment(image: UIImage(cgImage: frame))
                attachment.name = "Motion graph in encoded replay"; attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
