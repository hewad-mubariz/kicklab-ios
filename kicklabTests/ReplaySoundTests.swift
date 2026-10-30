import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import kicklab

struct ReplaySoundTests {
    private static let touchSounds = TouchSound.allCases.filter { $0 != .none }.map { ReplaySound.touch($0) }
    private static let swapSounds = BallSwapSound.allCases.filter { $0 != .none }.map { ReplaySound.swap($0) }

    @Test(arguments: touchSounds + swapSounds)
    func everyCueIsShortBoundedAndAudible(sound: ReplaySound) {
        let samples = ReplaySoundSynth.samples(sound)
        #expect(!samples.isEmpty)
        #expect(ReplaySoundSynth.duration(sound) <= 0.65, "Cues stay short so touches never pile up")
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(samples.map { abs($0) }.max()! > 0.5, "A cue must be clearly audible after normalizing")
        #expect(abs(samples.last!) < 0.05, "Cues fade out instead of clicking")
        #expect(samples == ReplaySoundSynth.samples(sound), "The cache returns the same render")
    }

    @Test func silentChoicesProduceNothing() {
        #expect(ReplaySoundSynth.samples(.touch(.none)).isEmpty)
        #expect(ReplaySoundSynth.samples(.swap(.none)).isEmpty)
        #expect(ReplaySound.touch(.none).isSilent && ReplaySound.swap(.none).isSilent)
        #expect(!ReplaySound.touch(.pop).isSilent)
    }

    @Test func soundtrackPlacesCuesAtTouchesAndChanges() {
        var edit = SessionEditState(style: .none, intensity: 0)
        edit.touchSound = .pop
        edit.swapSound = .chime
        edit.ballChanges = [1: .lava]
        let soundtrack = ReplaySoundtrack(edit: edit, touchTimes: [0.5, 1.0, 1.5])
        #expect(soundtrack.events.map(\.time) == [0.5, 1.0, 1.0, 1.5])
        #expect(soundtrack.events.filter { $0.sound == .swap(.chime) }.map(\.time) == [1.0])
        let audio = soundtrack.render(duration: 2)
        #expect(audio.count == 88_200)
        func rms(_ from: Double, _ to: Double) -> Float {
            let slice = audio[Int(from * 44_100)..<Int(to * 44_100)]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }
        #expect(rms(0.1, 0.45) == 0, "Nothing plays before the first touch")
        #expect(rms(0.5, 0.56) > 0.1, "The touch cue starts on the touch")
        #expect(rms(1.0, 1.08) > rms(0.5, 0.58), "Touch and change cues stack at the change")
        #expect(audio.allSatisfy { abs($0) <= 1 })
        // Nothing to play without touches, or with every sound off.
        #expect(ReplaySoundtrack(edit: edit, touchTimes: []).isEmpty)
        edit.touchSound = .none; edit.ballChanges = [:]
        #expect(ReplaySoundtrack(edit: edit, touchTimes: [0.5, 1.0]).isEmpty, "A change sound needs a change")
    }

    @Test func eventsAfterThroughSelectsAHalfOpenRange() {
        let soundtrack = ReplaySoundtrack(events: [1, 2, 3, 4].map { .init(time: $0, sound: .touch(.click)) })
        #expect(soundtrack.events(after: 1, through: 3).map(\.time) == [2, 3])
        #expect(soundtrack.events(after: 0, through: 0.5).isEmpty)
        #expect(soundtrack.events(after: 3, through: 2).isEmpty)
        #expect(soundtrack.events(after: 3.5, through: 10).map(\.time) == [4])
        #expect(ReplaySoundtrack(events: [.init(time: -1, sound: .touch(.pop)), .init(time: .nan, sound: .touch(.pop))]).isEmpty)
    }

    /// A tiny silent clip, so the export has only the cues to carry.
    private func silentClip(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-sound-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 128])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 128])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 30)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixels: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixels)
            CVPixelBufferLockBaseAddress(pixels!, [])
            memset(CVPixelBufferGetBaseAddress(pixels!), Int32(40 + index), CVPixelBufferGetBytesPerRow(pixels!) * 128)
            CVPixelBufferUnlockBaseAddress(pixels!, [])
            #expect(adaptor.append(pixels!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func mono(_ url: URL, duration: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1, "Cues and the clip's audio are one track, not two")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        #expect(reader.startReading())
        var samples = [Float](repeating: 0, count: Int(duration * 44_100) + 4410)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let start = Int((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 44_100).rounded())
            for (offset, value) in chunk.enumerated() where start + offset < samples.count && start + offset >= 0 {
                samples[start + offset] = value
            }
        }
        return samples
    }

    @Test func exportMixesCuesIntoTheSavedVideo() async throws {
        let source = try await silentClip(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let soundtrack = ReplaySoundtrack(events: [.init(time: 0.5, sound: .touch(.kick)), .init(time: 1.5, sound: .swap(.chime))])
        let exported = try await BallStyleBurnIn.render(source: source, track: [], style: .none, intensity: 0, shortEdge: 64,
                                                        soundtrack: soundtrack)
        defer { try? FileManager.default.removeItem(at: exported) }
        let asset = AVURLAsset(url: exported)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 2) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let audio = try await mono(exported, duration: 2)
        func rms(_ from: Double, _ to: Double) -> Float {
            let slice = audio[Int(from * 44_100)..<Int(to * 44_100)]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }
        #expect(rms(0.05, 0.45) < 0.01, "Silence where the clip and the cues are silent")
        #expect(rms(0.5, 0.6) > 0.05, "The touch cue is in the saved audio")
        #expect(rms(1.5, 1.6) > 0.03, "The change cue is in the saved audio")
        #expect(rms(1.0, 1.4) < 0.01)
        // Without cues the silent clip stays silent and gets no audio track at all.
        let plain = try await BallStyleBurnIn.render(source: source, track: [], style: .none, intensity: 0, shortEdge: 64)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(try await AVURLAsset(url: plain).loadTracks(withMediaType: .audio).isEmpty)
    }
}
