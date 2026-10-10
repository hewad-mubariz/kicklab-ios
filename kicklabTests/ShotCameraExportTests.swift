import AVFoundation
import CoreImage
import XCTest
@testable import kicklab

final class ShotCameraExportTests: XCTestCase {
    private func fixture(folder: URL, size: CGSize, sound: Bool) async throws -> (URL, BallEffectTrack) {
        let url = folder.appendingPathComponent(UUID().uuidString + ".mp4")
        let movie = try PreviewMovie(url: url, size: size, frameRate: 30)
        var frames: [RecordedFrame] = []
        let width = Int(size.width), height = Int(size.height)
        for index in 0..<36 {
            let pixels = try movie.buffer()
            CVPixelBufferLockBaseAddress(pixels, [])
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height { for x in 0..<width {
                let offset = y * stride + x * 4
                let white = abs(x - width * 3 / 4) < 5 && abs(y - height * 3 / 5) < 5
                bytes[offset] = white ? 255 : UInt8(40 + index * 4)
                bytes[offset + 1] = white ? 255 : 35
                bytes[offset + 2] = white ? 255 : 20
                bytes[offset + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(pixels, [])
            try await movie.append(pixels, time: CMTime(value: Int64(index), timescale: 30))
            frames.append(RecordedFrame(time: Double(index) / 30, x: 0.75, y: 0.6, width: 10 / size.width,
                height: 10 / size.height, score: 0.9, smoothedX: 0.75, smoothedY: 0.6, vy: 0,
                motion: .unknown, detected: true, person: nil))
        }
        try await movie.finish(duration: CMTime(value: 36, timescale: 30))
        guard sound else { return (url, BallEffectTrack(frames: frames)) }
        let wave = folder.appendingPathComponent("tone.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 52_920))
            buffer.frameLength = 52_920
            let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
            for index in 0..<52_920 { channel[index] = Float(0.2 * sin(Double(index) * 2 * .pi * 440 / 44_100)) }
            let file = try AVAudioFile(forWriting: wave, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            try file.write(from: buffer)
        } catch { throw NSError(domain: "ShotCameraFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Writing sound fixture: \(error)"]) }
        let asset = AVMutableComposition()
        let videoAsset = AVURLAsset(url: url), audioAsset = AVURLAsset(url: wave)
        let videos = try await videoAsset.loadTracks(withMediaType: .video)
        let sounds = try await audioAsset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videos.first)
        let audio = try XCTUnwrap(sounds.first)
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 36, timescale: 30))
        do {
            try withExtendedLifetime((videoAsset, audioAsset)) {
                try asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
                    .insertTimeRange(range, of: video, at: .zero)
                try asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                    .insertTimeRange(range, of: audio, at: .zero)
            }
        } catch { throw NSError(domain: "ShotCameraFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Combining sound fixture: \(error)"]) }
        let combined = folder.appendingPathComponent("with-sound.mp4")
        let export = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
        do { try await export.export(to: combined, as: .mp4) }
        catch { throw NSError(domain: "ShotCameraFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Encoding sound fixture: \(error)"]) }
        return (combined, BallEffectTrack(frames: frames))
    }

    private func meanBlue(_ asset: AVAsset, at time: Double) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)).image
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double((0..<(width * height)).reduce(0) { $0 + Int(bytes[$1 * 4 + 2]) }) / Double(width * height)
    }

    private func rms(_ asset: AVAsset, from start: Double, to end: Double) async throws -> Double {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var squares = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0, total = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                             totalLengthOut: &total, dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            let stamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for index in 0..<(total / 4) {
                let time = stamp + Double(index) / 44_100
                if time >= start && time < end { squares += pow(Double(values[index]), 2); count += 1 }
            }
        }
        XCTAssertNotEqual(reader.status, .failed, reader.error?.localizedDescription ?? "")
        XCTAssertGreaterThan(count, 100)
        return sqrt(squares / Double(max(1, count)))
    }

    func testRetimedExportsKeepSoundAndFreezeTheRequestedSourceFrame() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source: URL, track: BallEffectTrack
        do { (source, track) = try await fixture(folder: folder, size: CGSize(width: 320, height: 180), sound: true) }
        catch { XCTFail("Source sound fixture failed: \(error)"); return }
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        for style in [ShotCameraStyle.ramp, .freeze] {
            let camera = ShotCameraSettings(style: style, strike: 0.3)
            let clock = ShotReplayClock(settings: camera, track: track, flight: nil, duration: sourceDuration)
            let output: URL
            do { output = try await ShotEffectExporter.render(source: source, track: track, style: .none, camera: camera) { _ in } }
            catch { XCTFail("\(style.title) export failed: \(error)"); return }
            defer { try? FileManager.default.removeItem(at: output) }
            let asset = AVURLAsset(url: output)
            let actualDuration = try await asset.load(.duration).seconds
            XCTAssertEqual(actualDuration, clock.outputDuration, accuracy: 0.06)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1, "A replay must keep its soundtrack")
            let audible = try await rms(asset, from: 0.04, to: 0.15)
            XCTAssertGreaterThan(audible, 0.05)
            if style == .freeze {
                let quiet = try await rms(asset, from: 0.5, to: 0.7)
                XCTAssertLessThan(quiet, 0.008, "The inserted freeze has silence, not misplaced contact sound")
                let a = try await meanBlue(asset, at: 0.45), b = try await meanBlue(asset, at: 0.75)
                XCTAssertEqual(a, b, accuracy: 2, "The pixels hold on one source frame")
                let resumed = try await meanBlue(asset, at: 1.2)
                XCTAssertGreaterThan(resumed, b + 12, "The original footage resumes after the hold")
            } else {
                let a = try await meanBlue(asset, at: 0.3), b = try await meanBlue(asset, at: 0.7)
                let firstSource = try await meanBlue(AVURLAsset(url: source), at: 0.225)
                let secondSource = try await meanBlue(AVURLAsset(url: source), at: 0.325)
                XCTAssertEqual(a, firstSource, accuracy: 6)
                XCTAssertEqual(b, secondSource, accuracy: 6)
                XCTAssertGreaterThan(b, a)
                XCTAssertLessThan(b - a, 20, "The contact footage advances at quarter speed")
            }
        }
    }

    func testCustomReplayControlsReachTheExportWithSound() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (source, track) = try await fixture(folder: folder, size: CGSize(width: 320, height: 180), sound: true)
        for style in [ShotCameraStyle.ramp, .freeze] {
            var settings = ShotCameraSettings(style: style, strike: 0.3)
            settings.ranges[.ramp] = ShotSourceRange(start: 0.5, end: 0.9)
            settings.rampRate = 0.5; settings.smoothRamp = true
            settings.freezeFrame = 0.5; settings.freezeHold = 1.1
            let clock = ShotReplayClock(settings: settings, track: track, flight: nil, duration: 1.2)
            let output = try await ShotEffectExporter.render(source: source, track: track, style: .none, camera: settings) { _ in }
            defer { try? FileManager.default.removeItem(at: output) }
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, clock.outputDuration, accuracy: 0.035)
            let audible = try await rms(asset, from: 0.1, to: 0.3)
            XCTAssertGreaterThan(audible, 0.05)
            if style == .freeze {
                let a = try await meanBlue(asset, at: 0.7), b = try await meanBlue(asset, at: 1.4)
                XCTAssertEqual(a, b, accuracy: 2)
                let quiet = try await rms(asset, from: 0.8, to: 1.2)
                XCTAssertLessThan(quiet, 0.008)
            } else {
                let a = try await meanBlue(asset, at: clock.outputTime(for: 0.7))
                let original = try await meanBlue(AVURLAsset(url: source), at: 0.7)
                XCTAssertEqual(a, original, accuracy: 6)
            }
        }
    }

    func testCameraOnlyExportWorksForBothVideoOrientations() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for size in [CGSize(width: 320, height: 180), CGSize(width: 180, height: 320)] {
            let (source, track) = try await fixture(folder: folder, size: size, sound: false)
            for style in [ShotCameraStyle.follow, .impact, .lens, .tilt, .split] {
                let camera = ShotCameraSettings(style: style, strike: 0.3)
                let output = try await ShotEffectExporter.render(source: source, track: track, style: .none, camera: camera) { _ in }
                defer { try? FileManager.default.removeItem(at: output) }
                let asset = AVURLAsset(url: output)
                let videos = try await asset.loadTracks(withMediaType: .video)
                let video = try XCTUnwrap(videos.first)
                let outputSize = try await video.load(.naturalSize)
                XCTAssertEqual(outputSize, size, "Keep portrait and landscape orientation")
                let duration = try await asset.load(.duration).seconds
                XCTAssertEqual(duration, 1.2, accuracy: 0.04)
                let still = try await EffectVideoGeometry.still(asset: asset, at: 0.3, shortEdge: 320)
                XCTAssertEqual(still.image.width, Int(size.width)); XCTAssertEqual(still.image.height, Int(size.height))
            }
        }
    }
}
