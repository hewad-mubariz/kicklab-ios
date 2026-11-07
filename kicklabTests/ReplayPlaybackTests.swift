import AVFoundation
import MetalKit
import UIKit
import XCTest
@testable import kicklab

@MainActor
final class ReplayPlaybackTests: XCTestCase {
    func testEffectSurfaceBoundsTransientOversizedLayouts() {
        let view = EffectVideoView()
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 6178.5)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.drawableSize.height, 0)
        XCTAssertLessThanOrEqual(max(view.drawableSize.width, view.drawableSize.height), 4096)
        XCTAssertEqual(view.drawableSize.width / view.drawableSize.height, 402 / 6178.5, accuracy: 0.001)
        view.stop()
    }

    func testFreeLookAndNonVisualEditsUseNativePlayback() {
        let paid = JugglingReplayLook(edit: .init(style: .fire, ballSkin: .gold, environment: .night),
            overlays: .init(), showGraph: true)
        XCTAssertFalse(ReplayPlaybackSelection(edit: paid.allowed(isPro: false).edit).usesCompositor)
        var plain = SessionEditState(style: .none)
        plain.touchSound = .kick; plain.clipAudio = false
        XCTAssertFalse(ReplayPlaybackSelection(edit: plain).usesCompositor)
        XCTAssertFalse(ReplayPlaybackSelection(edit: .init(style: .fire, intensity: 0)).usesCompositor)
        for edit in [SessionEditState(style: .fire), .init(style: .none, ballSkin: .gold),
                     .init(style: .none, environment: .night)] {
            XCTAssertTrue(ReplayPlaybackSelection(edit: edit).usesCompositor)
        }
    }

    func testPlainReplayDoesNotReadOrConvertSourceAndRetainsAnalysis() async throws {
        let source = URL(fileURLWithPath: "/missing-\(UUID()).mov")
        let frame = RecordedFrame(time: 0.2, x: 0.5, y: 0.6, width: 0.1, height: 0.1, score: 1,
            smoothedX: 0.5, smoothedY: 0.6, vy: 0, motion: .unknown, detected: true, person: nil)
        var summary = SessionSummary.make(touches: 1, duration: 2, bestCombo: 1, personalBest: 1,
            videoURL: source, touchesMarked: [.init(index: 0, time: 0.2, x: 0.5, y: 0.6)], track: [frame])
        summary.needsVisualPreparation = true
        let selection = ReplayPlaybackSelection(edit: .init(style: .none))
        let media = try await selection.media(summary: summary, sceneModel: StadiumPreviewModel())
        XCTAssertEqual(media.url, source)
        XCTAssertEqual(media.track.map(\.time), [0.2])
        let item = try await selection.playerItem(asset: AVURLAsset(url: media.url))
        XCTAssertNil(item.videoComposition)
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, source)
    }

    func testEffectSelectionKeepsExistingCompositionAndCanReturnToOriginal() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-sixty", withExtension: "mov"))
        let asset = AVURLAsset(url: source)
        let effect = try await ReplayPlaybackSelection(edit: .init(style: .fire)).playerItem(asset: asset)
        XCTAssertNotNil(effect.videoComposition)
        let original = try await ReplayPlaybackSelection(edit: .init(style: .none)).playerItem(asset: asset)
        XCTAssertNil(original.videoComposition)
        XCTAssertEqual((original.asset as? AVURLAsset)?.url, source)
    }

    /// Reuses the existing phone benchmark asset; never creates a second full movie.
    func testOriginalHDRClipDisplaysAndSeeksWithoutAProxy() async throws {
        let source = URL.documentsDirectory.appendingPathComponent("pipeline-9064.mov")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Requires the existing 52-second HDR benchmark on the device")
        }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        XCTAssertTrue(descriptions.contains {
            let transfer = CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? ""
            return transfer.contains("HLG") || transfer.contains("2084") || transfer.contains("PQ")
        })
        let start = ProcessInfo.processInfo.systemUptime
        let item = try await ReplayPlaybackSelection(edit: .init(style: .none)).playerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = OriginalReplayView(frame: controller.view.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        defer { player.pause(); view.stop(); window.isHidden = true; previous?.makeKey() }
        var failure: String?
        view.onFailure = { failure = $0 }
        view.configure(player)
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        while !view.playerLayer.isReadyForDisplay, failure == nil,
              ProcessInfo.processInfo.systemUptime - start < 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(failure)
        XCTAssertTrue(view.playerLayer.isReadyForDisplay)
        XCTAssertNil(item.videoComposition)
        XCTAssertTrue(item.outputs.isEmpty)
        print("NATIVE_HDR_READY_SECONDS=\(ProcessInfo.processInfo.systemUptime - start)")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(player.currentTime().seconds, 2.2)
        player.pause()
        await player.seek(to: CMTime(seconds: 40, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertEqual(player.currentTime().seconds, 40, accuracy: 0.05)
        try await Task.sleep(for: .milliseconds(150))
    }
}
