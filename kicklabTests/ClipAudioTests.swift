import AVFoundation
import XCTest
@testable import kicklab

/// An iPhone clip with spatial audio carries its sound twice: an enabled 4-channel APAC track and a
/// disabled stereo AAC copy (the fixture is two seconds of such a clip). Saved videos keep one copy,
/// so the sound is neither played twice nor mixed with itself.
final class ClipAudioTests: XCTestCase {
    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/spatial-audio-2s.mov")

    func testSpatialClipKeepsOnlyItsStereoCopy() async throws {
        let asset = AVURLAsset(url: fixture)
        let all = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(all.count, 2)
        let kept = try await ClipAudio.tracks(of: asset)
        XCTAssertEqual(kept.count, 1)
        let enabled = try await kept[0].load(.isEnabled)
        XCTAssertFalse(enabled, "The stereo AAC copy, not the spatial track")
    }

    func testSavedVideoHasOneCopyOfTheSoundAtItsOwnLevel() async throws {
        let asset = AVURLAsset(url: fixture)
        let reference = try await Self.level(of: asset, tracks: ClipAudio.tracks(of: asset))
        let doubled = try await Self.level(of: asset, tracks: asset.loadTracks(withMediaType: .audio))
        print("CLIPAUDIO level one copy", reference, "both tracks", doubled)
        XCTAssertGreaterThan(reference, 0.001, "The fixture has sound")

        // Without replay sounds the clip's audio is copied into the saved video.
        let copied = try await BallStyleBurnIn.render(source: fixture, track: [], style: .none, intensity: 0, shortEdge: 360)
        defer { try? FileManager.default.removeItem(at: copied) }
        let copiedAsset = AVURLAsset(url: copied)
        let copiedTracks = try await copiedAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(copiedTracks.count, 1, "One audio track, so no player hears it twice")
        let copiedLevel = try await Self.level(of: copiedAsset, tracks: copiedTracks)
        XCTAssertEqual(copiedLevel / reference, 1, accuracy: 0.1)

        // With replay sounds it is mixed with the cues; outside them it keeps its own level.
        let soundtrack = ReplaySoundtrack(edit: SessionEditState(style: .none, intensity: 0), touchTimes: [])
        let mixed = try await soundtrack.mixedAudio(source: asset, duration: asset.load(.duration))
        defer { try? FileManager.default.removeItem(at: mixed) }
        let mixedAsset = AVURLAsset(url: mixed)
        let mixedLevel = try await Self.level(of: mixedAsset, tracks: mixedAsset.loadTracks(withMediaType: .audio))
        print("CLIPAUDIO level saved copy", copiedLevel, "mixed", mixedLevel)
        XCTAssertEqual(mixedLevel / reference, 1, accuracy: 0.15)
    }

    /// RMS of the tracks decoded and mixed to stereo, as a player would hear them together.
    private static func level(of asset: AVAsset, tracks: [AVAssetTrack]) async throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var sum = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for v in values { sum += Double(v * v) }
            count += values.count
        }
        return count == 0 ? 0 : (sum / Double(count)).squareRoot()
    }
}
