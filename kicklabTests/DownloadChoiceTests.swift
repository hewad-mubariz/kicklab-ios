import AVFoundation
import XCTest
@testable import kicklab

/// Downloading a clip above 1080p or 60 fps offers the faster 1080p at up to 60 fps or the original.
/// The faster download keeps the same frames the 60 fps outline pass reads, so every saved frame of a
/// replacement ball has its own silhouette.
final class DownloadChoiceTests: XCTestCase {
    private func info(_ width: Double, _ height: Double, _ fps: Double) -> VideoProcessingInfo {
        VideoProcessingInfo(size: CGSize(width: width, height: height), fps: fps, duration: 20)
    }

    func testChoicesFollowTheClip() {
        XCTAssertNil(ExportChoice.choices(for: info(1080, 1920, 30)).original)
        XCTAssertNil(ExportChoice.choices(for: info(720, 1280, 60)).original, "In-app recordings save as before")
        XCTAssertNil(ExportChoice.choices(for: info(1080, 1920, 59.94)).original)

        let camera = ExportChoice.choices(for: info(2160, 3840, 119.94))
        XCTAssertEqual(camera.faster.label, "1080p · 60 fps")
        XCTAssertEqual(camera.faster.shortEdge, 1080)
        XCTAssertEqual(camera.faster.maxFrameRate, 60)
        XCTAssertEqual(camera.original?.label, "4K · 120 fps")
        XCTAssertNil(camera.original?.shortEdge)
        XCTAssertEqual(camera.original?.keepsEveryFrame, true)

        XCTAssertEqual(ExportChoice.choices(for: info(3840, 2160, 30)).faster.label, "1080p · 30 fps")
        XCTAssertEqual(ExportChoice.choices(for: info(3840, 2160, 30)).original?.label, "4K · 30 fps")
        XCTAssertEqual(ExportChoice.choices(for: info(1080, 1920, 120)).original?.label, "1080p · 120 fps")
    }

    func testFrameSpacingKeepsEveryFrameUnlessTheClipIsFaster() {
        XCTAssertEqual(VideoExportFormat.spacing(maxFrameRate: 60, sourceFrameRate: 60), 0)
        XCTAssertEqual(VideoExportFormat.spacing(maxFrameRate: 60, sourceFrameRate: 30), 0)
        XCTAssertEqual(VideoExportFormat.spacing(maxFrameRate: 60, sourceFrameRate: 120), 1.0 / 60 - 0.5 / 120, accuracy: 1e-9)
        XCTAssertEqual(VideoExportFormat.spacing(maxFrameRate: 60, sourceFrameRate: 240), 1.0 / 60 - 0.5 / 240, accuracy: 1e-9)
        XCTAssertEqual(BallStyleBurnIn.bitrate(for: CGSize(width: 2160, height: 3840), frameRate: 120), 60_000_000)
        XCTAssertEqual(BallStyleBurnIn.bitrate(for: CGSize(width: 2160, height: 3840), frameRate: 30), 40_000_000)
        XCTAssertEqual(BallStyleBurnIn.bitrate(for: CGSize(width: 1080, height: 1920), frameRate: 120), 14_000_000)
    }

    private func frames(of url: URL) async throws -> (times: [Double], size: CGSize, codec: FourCharCode?) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let codec = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        let reader = try AVAssetReader(asset: asset)
        // Decoded frames carry presentation times after the encoder's start delay is removed.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { times.append(sample.presentationTimeStamp.seconds) }
        }
        return (times.sorted(), size, codec)
    }

    @MainActor
    func testFasterDownloadOfAFastClipKeepsTheOutlinedFramesAndTheOriginalKeepsThemAll() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-sixty-as-120", withExtension: "mov"))
        let every = try await VideoAnalyzer.replayTrack(source: source)
        XCTAssertEqual(every.count, 90)
        // An import of this 120 fps clip is counted at 30 fps: every fourth source frame.
        let counted = every.filter { ($0.identity?.index ?? 1) % 4 == 0 }
        var summary = SessionSummary.make(touches: 0, duration: 0.75, bestCombo: 0, personalBest: 0,
                                          videoURL: source, touchesMarked: [], track: counted)
        summary.framesUseCompositionClock = true
        summary.needsVisualPreparation = true
        let lava = SessionEditState(style: .none, intensity: 0, ballSkin: .gold)
        let preparation = SessionEffectsPreparation()

        let faster = try await preparation.prepare(summary, for: lava)
        let outlined = faster.renderTrack.filter { !$0.isVisualMaskRepair && !$0.isVisualRecovery }
        XCTAssertEqual(outlined.count, 45, "Outlines at the faster download's 60 fps")
        XCTAssertFalse(BallVisualRefiner.analysedEveryFrame(faster.renderTrack))

        let fasterVideo = try await BallStyleBurnIn.render(source: source, track: faster.renderTrack, style: .none,
                                                           skin: .gold, intensity: 0.8, shortEdge: 1080, maxFrameRate: 60)
        defer { try? FileManager.default.removeItem(at: fasterVideo) }
        let saved = try await frames(of: fasterVideo)
        XCTAssertEqual(saved.times.count, 45)
        XCTAssertEqual(fasterVideo.pathExtension, "mp4")
        let track = BallEffectTrack(frames: faster.renderTrack)
        for time in saved.times { XCTAssertNotNil(track.mask(at: time), "saved frame at \(time) has no silhouette") }

        let original = try await preparation.prepare(summary, for: lava, everyFrame: true)
        XCTAssertEqual(original.renderTrack.filter { !$0.isVisualMaskRepair && !$0.isVisualRecovery }.count, 90)
        let originalVideo = try await BallStyleBurnIn.render(source: source, track: original.renderTrack, style: .none,
                                                             skin: .gold, intensity: 0.8, shortEdge: nil)
        defer { try? FileManager.default.removeItem(at: originalVideo) }
        let all = try await frames(of: originalVideo)
        XCTAssertEqual(all.times.count, 90)
        XCTAssertEqual(all.size, CGSize(width: 720, height: 1280), "The original keeps the source size")
        XCTAssertEqual(originalVideo.pathExtension, "mov", "Above 60 fps keeps the full-speed playback intent")
        XCTAssertEqual(all.codec, kCMVideoCodecType_H264, "1080p and below stay H.264")
    }
}
