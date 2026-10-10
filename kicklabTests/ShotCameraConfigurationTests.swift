import AVFoundation
import Metal
import simd
import UIKit
import XCTest
@testable import kicklab

final class ShotCameraConfigurationTests: XCTestCase {
    private var empty: BallEffectTrack { BallEffectTrack(frames: []) }

    func testCustomRampRatesRangesAndTransitionsRoundTrip() {
        for rate in [0.25, 0.5, 1.0] {
            for smooth in [false, true] {
                var settings = ShotCameraSettings(style: .ramp, strike: 0.2)
                settings.ranges[.ramp] = ShotSourceRange(start: 1.3, end: 2.1)
                settings.rampRate = rate; settings.smoothRamp = smooth
                let clock = ShotReplayClock(settings: settings, track: empty, flight: nil, duration: 4)
                for source in stride(from: 0.0, through: 4, by: 0.007) {
                    XCTAssertEqual(clock.sourceTime(for: clock.outputTime(for: source)), source, accuracy: 0.00001)
                }
                XCTAssertEqual(clock.outputTime(for: 1), 1, accuracy: 0.00001)
                XCTAssertEqual(clock.outputTime(for: 3.1) - clock.outputTime(for: 3), 0.1, accuracy: 0.00001)
                XCTAssertEqual(clock.outputTime(for: 1.71) - clock.outputTime(for: 1.7), 0.01 / rate, accuracy: 0.00001)
            }
        }
    }
    func testFreezeOverrideAndCustomHoldKeepSourceClock() {
        var settings = ShotCameraSettings(style: .freeze, strike: 0.4)
        settings.freezeFrame = 1.2; settings.freezeHold = 1.5
        let clock = ShotReplayClock(settings: settings, track: empty, flight: nil, duration: 4)
        XCTAssertEqual(clock.outputDuration, 5.5)
        XCTAssertEqual(clock.sourceTime(for: 2.6), 1.2)
        XCTAssertEqual(clock.sourceTime(for: 3), 1.5)
        XCTAssertEqual(clock.outputTime(for: 1.2), 1.2)
    }
    func testAdjacentFramesUseActualVariableTimestampsAndClampAtEdges() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let frames = try await ShotSourceFrames.load(source)
        XCTAssertGreaterThan(frames.times.count, 10)
        let gaps = zip(frames.times, frames.times.dropFirst()).map { Int((($1 - $0) * 100_000).rounded()) }
        XCTAssertGreaterThan(Set(gaps).count, 1, "This fixture has variable source cadence")
        for i in 1..<frames.times.count - 1 {
            XCTAssertEqual(frames.adjacent(to: frames.times[i], by: -1), frames.times[i - 1])
            XCTAssertEqual(frames.adjacent(to: frames.times[i], by: 1), frames.times[i + 1])
            XCTAssertEqual(frames.frameDuration(at: frames.times[i]), frames.times[i + 1] - frames.times[i], accuracy: 0.00001)
        }
        XCTAssertEqual(frames.adjacent(to: 0, by: -1), frames.times.first)
        XCTAssertEqual(frames.adjacent(to: frames.duration, by: 1), frames.times.last)
    }
    func testManualTargetsWorkWithoutTrackingAndRangesDoNotLeak() {
        for style in [ShotCameraStyle.follow, .lens, .split] {
            var settings = ShotCameraSettings(style: style, strike: 1)
            settings.followTarget = ShotCameraPoint(x: 0.7, y: 0.6)
            settings.lensTarget = ShotCameraPoint(x: 0.7, y: 0.6)
            settings.ranges[style] = ShotSourceRange(start: 1, end: 2)
            for time in [0.5, 2.1] {
                XCTAssertFalse(ShotCameraFrame.make(settings: settings, track: empty, flight: nil, size: CGSize(width: 180, height: 320), time: time).isActive)
            }
            XCTAssertTrue(ShotCameraFrame.make(settings: settings, track: empty, flight: nil, size: CGSize(width: 180, height: 320), time: 1.5).isActive)
        }
        var impact = ShotCameraSettings(style: .impact, strike: 1)
        impact.impactTarget = ShotCameraPoint(x: 0.3, y: 0.7); impact.impactDuration = 1
        XCTAssertTrue(ShotCameraFrame.make(settings: impact, track: empty, flight: nil, size: CGSize(width: 320, height: 180), time: 1).isActive)
        XCTAssertFalse(ShotCameraFrame.make(settings: impact, track: empty, flight: nil, size: CGSize(width: 320, height: 180), time: 1.6).isActive)
    }
    func testVFRFrameSelectionAndFreezeDecodeTheChosenSourcePixels() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let frames = try await ShotSourceFrames.load(source)
        let asset = AVURLAsset(url: source)
        func still(_ asset: AVAsset, _ time: Double) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 120, height: 120)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: time + 0.000001, preferredTimescale: 1_800_000_000)).image
        }
        let picked = frames.times[frames.times.count / 2]
        var settings = ShotCameraSettings(style: .freeze)
        settings.freezeFrame = picked; settings.freezeHold = 1.3
        let clock = ShotReplayClock(settings: settings, track: empty, flight: nil, duration: frames.duration)
        let retimed = try await clock.asset(source: source)
        let duration = try await retimed.load(.duration).seconds
        XCTAssertEqual(duration, clock.outputDuration, accuracy: 0.0001)
        let reference = try await still(asset, picked)
        func rgba(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        for time in [picked + 0.15, picked + 1.1] {
            let held = try await still(retimed, time)
            XCTAssertEqual(held.width, reference.width); XCTAssertEqual(held.height, reference.height)
            let a = rgba(reference), b = rgba(held)
            XCTAssertEqual(a.count, b.count)
            let difference = zip(a,b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            let mean = Double(difference) / Double(a.count)
            if mean > 1 {
                print("VFR freeze: picked=\(picked), hold sample=\(time), length=\(frames.frameDuration(at: picked)), difference=\(mean)")
                for (name, image) in [("VFR chosen source", reference), ("VFR held \(time)", held)] {
                    let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
            XCTAssertLessThan(mean, 1, "Hold the selected VFR frame, not a neighbouring sample")
        }
    }
    func testLensPositionAndSplitLayoutUseIdenticalCPUAndMetalPixels() throws {
        let engine = try MetalEffectEngine()
        for size in [CGSize(width: 180, height: 320), CGSize(width: 320, height: 180)] {
            let w = Int(size.width), h = Int(size.height)
            for style in [ShotCameraStyle.lens, .split] {
                var settings = ShotCameraSettings(style: style, strike: 0)
                settings.lensTarget = ShotCameraPoint(x: 0.8, y: 0.8)
                settings.lensPosition = ShotCameraPoint(x: 0.15, y: 0.8); settings.lensSize = .large; settings.lensZoom = 5
                settings.followTarget = ShotCameraPoint(x: 0.8, y: 0.8)
                settings.stackedSplit = true; settings.splitBalance = 0.65; settings.splitZoom = 2.6
                let camera = ShotCameraFrame.make(settings: settings, track: empty, flight: nil, size: size, time: 0)
                let frame = EffectFrame.shot(size: size, sourceSize: size, style: .none, intensity: 0, track: empty, time: 0)
                func buffer() throws -> CVPixelBuffer {
                    var buffer: CVPixelBuffer?
                    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
                    let pixels = try XCTUnwrap(buffer)
                    CVPixelBufferLockBaseAddress(pixels, [])
                    let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<h { for x in 0..<w {
                        let i = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                        bytes[i] = UInt8(x * 240 / w); bytes[i + 1] = UInt8(y * 240 / h); bytes[i + 2] = 50; bytes[i + 3] = 255
                    }}
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    return pixels
                }
                let cpu = try buffer(), gpu = try buffer()
                try ShotCPURenderer.composite(frame, pixelBuffer: cpu, camera: camera)
                try engine.composite(frame, pixelBuffer: gpu, camera: camera)
                CVPixelBufferLockBaseAddress(cpu, .readOnly); CVPixelBufferLockBaseAddress(gpu, .readOnly)
                let a = CVPixelBufferGetBaseAddress(cpu)!.assumingMemoryBound(to: UInt8.self), b = CVPixelBufferGetBaseAddress(gpu)!.assumingMemoryBound(to: UInt8.self)
                var sum = 0
                for y in 0..<h { for x in 0..<w { for c in 0..<3 {
                    sum += abs(Int(a[y * CVPixelBufferGetBytesPerRow(cpu) + x * 4 + c]) - Int(b[y * CVPixelBufferGetBytesPerRow(gpu) + x * 4 + c]))
                }}}
                XCTAssertLessThan(Double(sum) / Double(w * h * 3), 0.5)
                // The edited lens is on the left; the lower panel is the edited detail crop.
                let px = style == .lens ? Int(Double(camera.uniforms.inset.x) * Double(w)) : w / 2
                let py = style == .lens ? Int(Double(camera.uniforms.inset.y) * Double(h)) : Int(Double(h) * 0.825)
                let i = py * CVPixelBufferGetBytesPerRow(cpu) + px * 4
                XCTAssertGreaterThan(a[i], 150, "Edited source area is visible at the edited destination")
                CVPixelBufferUnlockBaseAddress(cpu, .readOnly); CVPixelBufferUnlockBaseAddress(gpu, .readOnly)
            }
        }
    }
    func testFreezePathTogglesAndEndpointOnlyAppearOnTheHeldFrame() {
        let track = BallEffectTrack(frames: (0...30).map { i in
            let t = Double(i) / 30
            return RecordedFrame(time: t, x: 0.2 + t * 0.3, y: 0.8 - t * 0.2, width: 0.04, height: 0.07,
                                 score: 0.9, smoothedX: 0.2 + t * 0.3, smoothedY: 0.8 - t * 0.2, vy: 0,
                                 motion: .unknown, detected: true, person: nil)
        })
        var settings = ShotCameraSettings(style: .freeze, strike: 0.2)
        settings.freezeFrame = 0.3; settings.pathEnd = 0.5
        let size = CGSize(width: 320, height: 180)
        let frame = ShotCameraFrame.make(settings: settings, track: track, flight: nil, size: size, time: 0.3)
        XCTAssertGreaterThan(frame.path.count, 2)
        XCTAssertEqual(frame.path.last!.x, 0.35, accuracy: 0.0001)
        XCTAssertGreaterThan(simd_length(SIMD2(frame.uniforms.guide.z, frame.uniforms.guide.w)), 0.9)
        XCTAssertFalse(ShotCameraFrame.make(settings: settings, track: track, flight: nil, size: size, time: 0.6).isActive)
        settings.showPath = false; settings.showDirection = false
        let hidden = ShotCameraFrame.make(settings: settings, track: track, flight: nil, size: size, time: 0.3)
        XCTAssertTrue(hidden.path.isEmpty); XCTAssertEqual(hidden.uniforms.guide, .zero)
    }
}
