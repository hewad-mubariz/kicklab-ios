import AVFoundation
import XCTest
@testable import kicklab

/// Camera recordings keep the microphone's sound when it's allowed, and record the picture alone when it isn't.
@MainActor
final class RecordingSoundTests: XCTestCase {
    private let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                      AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]

    func testSoundIsSavedWithThePictureForTheEditorToUse() async throws {
        let recorder = Recorder()
        try recorder.start(width: 64, height: 64, soundSettings: aac)
        XCTAssertFalse(recorder.appendSound(try sound(at: 0)), "Sound before the first frame was kept")
        let pixels = try pixelBuffer()
        var soundUntil = 0.0
        for frame in 0..<30 {
            try await append(pixels, to: recorder, frame: frame)
            while soundUntil < Double(frame + 1) / 30 {
                try await appendSound(try sound(at: soundUntil), to: recorder)
                soundUntil += 1_024 / 44_100
            }
        }
        let saved = try await stop(recorder).get()
        defer { try? FileManager.default.removeItem(at: saved) }
        let asset = AVURLAsset(url: saved)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let tracks = try await ClipAudio.tracks(of: asset)
        XCTAssertEqual(tracks.count, 1)
        let range = try await XCTUnwrap(tracks.first).load(.timeRange)
        XCTAssertGreaterThan(range.duration.seconds, 0.9)
        XCTAssertLessThan(range.start.seconds, 0.05)
    }

    func testWithoutMicrophoneAccessThePictureIsRecordedAlone() async throws {
        let recorder = Recorder()
        try recorder.start(width: 64, height: 64)
        XCTAssertFalse(recorder.appendSound(try sound(at: 0)))
        let pixels = try pixelBuffer()
        for frame in 0..<3 { try await append(pixels, to: recorder, frame: frame) }
        XCTAssertFalse(recorder.appendSound(try sound(at: 0.04)))
        let saved = try await stop(recorder).get()
        defer { try? FileManager.default.removeItem(at: saved) }
        let asset = AVURLAsset(url: saved)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertTrue(audio.isEmpty)
    }

    /// A microphone that delivers nothing, as during an interruption, must not cost the video.
    func testSilentMicrophoneStillSavesTheVideo() async throws {
        let recorder = Recorder()
        try recorder.start(width: 64, height: 64, soundSettings: aac)
        let pixels = try pixelBuffer()
        for frame in 0..<3 { try await append(pixels, to: recorder, frame: frame) }
        let saved = try await stop(recorder).get()
        defer { try? FileManager.default.removeItem(at: saved) }
        let video = try await AVURLAsset(url: saved).loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
    }

    private func sound(at seconds: Double, frames: Int = 1_024) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        let bytes = frames * 2
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), kCMBlockBufferNoErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes), kCMBlockBufferNoErr)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: data,
            formatDescription: try XCTUnwrap(format), sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 44_100),
            packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func append(_ pixels: CVPixelBuffer, to recorder: Recorder, frame: Int) async throws {
        for _ in 0..<100 {
            if try recorder.append(pixels, at: CMTime(value: Int64(frame), timescale: 30)) != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Writer never took the frame")
    }

    private func appendSound(_ sample: CMSampleBuffer, to recorder: Recorder) async throws {
        for _ in 0..<100 {
            if recorder.appendSound(sample) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Writer never took the sound")
    }

    private func stop(_ recorder: Recorder) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume(returning: $0) } }
    }
}
