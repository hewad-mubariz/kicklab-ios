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
                for background in [true, false] {
                    let rect = ExportMotionGraphRenderer.rect(style: style, background: background, in: size)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
                    let first = try XCTUnwrap(ExportMotionGraphRenderer.image(style: style,
                        snapshot: MotionStyleSample.timeline.snapshot(at: 2.1, duration: 5.6), size: size, background: background))
                    // Not 4.3: on the sample's steady 0.8 s beat it puts the metronome at the same point
                    // of the opposite swing as 2.1, so the two cards would be the same picture.
                    let second = try XCTUnwrap(ExportMotionGraphRenderer.image(style: style,
                        snapshot: MotionStyleSample.timeline.snapshot(at: MotionStyleSample.time, duration: 5.6), size: size, background: background))
                    XCTAssertGreaterThan(first.width, 0)
                    XCTAssertNotEqual(UIImage(cgImage: first).pngData(), UIImage(cgImage: second).pngData(),
                                      "\(style) must follow media time")
                }
            }
        }
    }

    /// The sample's fifth bounce is a new best (apex 3.6 s), so at 4.1 s Sky Meter shows NEW BEST!.
    /// The gold tag must end inside the graph, not run into its right edge and get cut off.
    @MainActor
    func testSkyMeterNewBestStaysInsideTheCard() throws {
        for background in [true, false] {
            let image = try XCTUnwrap(ExportMotionGraphRenderer.image(style: .skyMeter,
                snapshot: MotionStyleSample.timeline.snapshot(at: 4.1, duration: 5.6), size: CGSize(width: 1080, height: 1920), background: background))
            let width = ExportMotionGraphRenderer.width(background: background)
            let scale = CGFloat(image.width) / width
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            func gold(inColumns columns: Range<Int>) -> Int {
                var count = 0
                for y in 0..<image.height { for x in columns {
                    let i = (y * image.width + x) * 4
                    if pixels[i] > 200 && pixels[i + 1] > 140 && pixels[i + 2] < 120 { count += 1 }
                } }
                return count
            }
            // The graph spans the panel's width less its padding on each side.
            let edge = Int(((width - ExportMotionGraphRenderer.padding(background: background)) * scale).rounded())
            XCTAssertGreaterThan(gold(inColumns: (edge - Int(40 * scale))..<(edge - Int(2 * scale))), 0, "NEW BEST! is drawn")
            XCTAssertEqual(gold(inColumns: (edge - Int(1 * scale))..<edge), 0, "NEW BEST! must not touch the graph's right edge")
        }
    }

    /// The simple panel holds the place of the replay's readout: full width, ending above the scrubber.
    /// The black card floats inside the frame's margins at the bottom.
    func testPanelPlacesInAPortraitVideo() {
        let size = CGSize(width: 1080, height: 1920)
        let simple = ExportMotionGraphRenderer.rect(style: .ballMotion, background: false, in: size)
        XCTAssertEqual(simple.minX, 0)
        XCTAssertEqual(simple.width, 1080)
        XCTAssertEqual(simple.maxY, 1920 * 0.88, accuracy: 0.001)
        let card = ExportMotionGraphRenderer.rect(style: .ballMotion, background: true, in: size)
        XCTAssertEqual(card.minX, 1080 * 0.04, accuracy: 0.001)
        XCTAssertEqual(card.maxX, 1080 * 0.96, accuracy: 0.001)
        XCTAssertEqual(card.maxY, 1920 - 1080 * 0.04, accuracy: 0.001)
    }

    /// The black card darkens only its own rectangle; the simple view darkens the bottom of the file like the replay.
    func testBlackBackgroundOrSimpleViewInTheSavedVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let size = CGSize(width: 720, height: 1280)
        let movie = try PreviewMovie(url: source, size: size, frameRate: 30)
        let pixels = try movie.buffer()
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels)!, 150, CVPixelBufferGetBytesPerRow(pixels) * 1280)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<6 { try await movie.append(pixels, time: CMTime(value: Int64(frame), timescale: 30)) }
        try await movie.finish(duration: CMTime(value: 6, timescale: 30))

        func brightness(background: Bool) async throws -> (above: Int, inCard: Int, bottom: Int) {
            var settings = ExportOverlaySettings()
            settings.counter.enabled = false
            settings.timer.enabled = false
            settings.graph.enabled = true
            settings.graph.background = background
            let output = try await BallStyleBurnIn.render(source: source, track: [], style: .none,
                intensity: 0, shortEdge: 720, overlays: settings, motionTimeline: MotionStyleSample.timeline)
            defer { try? FileManager.default.removeItem(at: output) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: CMTime(value: 3, timescale: 30)).image
            var rgba = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: frame.width, height: frame.height, bitsPerComponent: 8,
                bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            func green(x: Int, y: Int) -> Int { Int(rgba[(y * frame.width + x) * 4 + 1]) }
            // Inside the card's padding, clear of its rounded corners and its text.
            let card = ExportMotionGraphRenderer.rect(style: .ballMotion, background: true, in: CGSize(width: frame.width, height: frame.height))
            return (green(x: frame.width / 2, y: frame.height * 40 / 100),
                    green(x: Int(card.minX) + 6, y: Int(card.midY)),
                    green(x: frame.width / 2, y: frame.height - 6))
        }
        let black = try await brightness(background: true)
        let simple = try await brightness(background: false)
        XCTAssertEqual(black.above, simple.above, accuracy: 3, "Above both the footage is untouched")
        XCTAssertLessThan(Double(black.inCard), Double(black.above) * 0.5, "The black card is drawn")
        XCTAssertEqual(black.bottom, black.above, accuracy: 3, "Below the card the footage is untouched")
        XCTAssertLessThan(Double(simple.bottom), Double(simple.above) * 0.35, "The simple view brings the replay's shade")
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

        for (enabled, background) in [(true, true), (true, false), (false, true)] {
            var settings = ExportOverlaySettings()
            settings.counter.enabled = false
            settings.graph.enabled = enabled
            settings.graph.background = background
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
            // The analytics are saved with the graph: the whole view, not the line alone.
            XCTAssertEqual(words.contains("RHYTHM"), enabled, "Encoded text: \(words)")
            XCTAssertEqual(words.contains("TOUCH INTERVAL"), enabled, "Encoded text: \(words)")
            if enabled {
                let attachment = XCTAttachment(image: UIImage(cgImage: frame))
                attachment.name = "Motion graph in encoded replay"; attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
