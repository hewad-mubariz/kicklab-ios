import AVFoundation
import XCTest
@testable import kicklab

final class ShotBackgroundExportTests: XCTestCase {
    private func track() -> BallEffectTrack {
        BallEffectTrack(frames: (0...60).map { i in
            let t = Double(i) / 60, f = max(0, t - 0.2)
            return RecordedFrame(time: t, x: 0.3 + f * 0.3, y: 0.8 - f * 0.6, width: 0.08, height: 0.045,
                score: 0.9, smoothedX: 0.3 + f * 0.3, smoothedY: 0.8 - f * 0.6, vy: 0,
                motion: .unknown, detected: true, person: nil)
        })
    }

    private func buffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 180, 320, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<320 { for x in 0..<180 {
            let p = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
            bytes[p] = UInt8(x); bytes[p + 1] = UInt8(y / 2); bytes[p + 2] = 35; bytes[p + 3] = 255
        }}
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    func testCPUAndMetalKeepEveryShotLookAndCamera() throws {
        let engine = try MetalEffectEngine(), track = track(), size = CGSize(width: 180, height: 320)
        // Cover every material and every spatial camera; timing-only cameras use this same renderer.
        for (i, style) in ShotTrailStyle.allCases.enumerated() {
            let cameras: [ShotCameraStyle] = [.none, .follow, .impact, .lens, .tilt, .split, .freeze]
            let camera = ShotCameraFrame.make(settings: .init(style: cameras[i % cameras.count], strike: 0.2), track: track,
                                              flight: nil, size: size, time: 0.7)
            let frame = EffectFrame.shot(size: size, sourceSize: size, style: style, intensity: 1, track: track, time: 0.7)
            let cpu = try buffer(), gpu = try buffer()
            try engine.composite(frame, pixelBuffer: gpu, camera: camera)
            try ShotCPURenderer.composite(frame, pixelBuffer: cpu, camera: camera)
            CVPixelBufferLockBaseAddress(cpu, .readOnly); CVPixelBufferLockBaseAddress(gpu, .readOnly)
            let a = CVPixelBufferGetBaseAddress(cpu)!.assumingMemoryBound(to: UInt8.self)
            let b = CVPixelBufferGetBaseAddress(gpu)!.assumingMemoryBound(to: UInt8.self)
            var differences: [Int] = []
            for y in 0..<320 { for x in 0..<180 { for c in 0..<3 {
                differences.append(abs(Int(a[y * CVPixelBufferGetBytesPerRow(cpu) + x * 4 + c]) - Int(b[y * CVPixelBufferGetBytesPerRow(gpu) + x * 4 + c])))
            }}}
            CVPixelBufferUnlockBaseAddress(cpu, .readOnly); CVPixelBufferUnlockBaseAddress(gpu, .readOnly)
            differences.sort()
            let mean = Double(differences.reduce(0, +)) / Double(differences.count)
            XCTAssertLessThan(mean, 2, "\(style): mean pixel difference")
            XCTAssertLessThan(differences[differences.count * 99 / 100], 18, "\(style): 99th percentile difference")
        }
    }

    func testCancellationDuringCPUExportCleansUpAndAllowsRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let movie = try PreviewMovie(url: source, size: CGSize(width: 180, height: 320), frameRate: 30)
        for index in 0..<30 { try await movie.append(buffer(), time: CMTime(value: Int64(index), timescale: 30)) }
        try await movie.finish(duration: CMTime(seconds: 1, preferredTimescale: 30))
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: URL.temporaryDirectory.path).filter { $0.hasPrefix("power-shot-") })
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        do {
            _ = try await VideoWorkExecution.$lease.withValue(lease) {
                try await ShotEffectExporter.render(source: source, track: track(), style: .fireTrail) { value in
                    if value >= 0.3 { lease.expire() }
                }
            }
            XCTFail("Cancellation must stop the export")
        } catch is CancellationError { } catch { XCTFail("Expected cancellation, got \(error)") }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: URL.temporaryDirectory.path).filter { $0.hasPrefix("power-shot-") })
        XCTAssertEqual(after, before, "A cancelled export must remove its partial output")
        let retryLease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        let output = try await VideoWorkExecution.$lease.withValue(retryLease) {
            try await ShotEffectExporter.render(source: source, track: track(), style: .fireTrail) { _ in }
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.04)
    }
}
