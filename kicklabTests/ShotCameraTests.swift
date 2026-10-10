import AVFoundation
import Metal
import XCTest
@testable import kicklab

final class ShotCameraTests: XCTestCase {
    private func track(times: [Double] = [0, 0.02, 0.04, 0.06], x: Double = 0.75, y: Double = 0.6) -> BallEffectTrack {
        BallEffectTrack(frames: times.map { time in
            RecordedFrame(time: time, x: x, y: y, width: 0.04, height: 0.07, score: 0.9,
                          smoothedX: x, smoothedY: y, vy: 0, motion: .unknown, detected: true, person: nil)
        })
    }

    func testRampedClockRoundTripsSourceTimingAndSlowsOnlyContact() {
        let clock = ShotReplayClock(mode: .ramp, strike: 1, duration: 3)
        XCTAssertEqual(clock.outputDuration, 3.84, accuracy: 0.0001)
        for source in stride(from: 0.0, through: 3, by: 0.013) {
            XCTAssertEqual(clock.sourceTime(for: clock.outputTime(for: source)), source, accuracy: 0.00001)
        }
        XCTAssertEqual(clock.outputTime(for: 1.02) - clock.outputTime(for: 1), 0.08, accuracy: 0.00001)
        XCTAssertEqual(clock.outputTime(for: 2.02) - clock.outputTime(for: 2), 0.02, accuracy: 0.00001)
    }

    func testFreezeHasAnUnambiguousSourceClockAndSeekEntersTheHold() {
        let clock = ShotReplayClock(mode: .freeze, strike: 1, duration: 3)
        XCTAssertEqual(clock.outputTime(for: 1), 1)
        XCTAssertEqual(clock.sourceTime(for: 1.3), 1)
        XCTAssertEqual(clock.sourceTime(for: 1.65), 1, accuracy: 0.00001)
        XCTAssertEqual(clock.sourceTime(for: 2), 1.35, accuracy: 0.00001)
        XCTAssertEqual(clock.outputDuration, 3.65, accuracy: 0.00001)
        for source in stride(from: 0.0, through: 3, by: 0.013) {
            XCTAssertEqual(clock.sourceTime(for: clock.outputTime(for: source)), source, accuracy: 0.00001)
        }
    }

    func testRampsAtClipEdgesRemainWithinTheSource() {
        for strike in [0.0, 0.99] {
            let clock = ShotReplayClock(mode: .ramp, strike: strike, duration: 1)
            for output in stride(from: 0.0, through: clock.outputDuration, by: 0.017) {
                XCTAssertGreaterThanOrEqual(clock.sourceTime(for: output), 0)
                XCTAssertLessThanOrEqual(clock.sourceTime(for: output), 1)
            }
        }
    }

    func testLostBallEasesBackToWideThenStopsFollowing() {
        let settings = ShotCameraSettings(style: .follow)
        let size = CGSize(width: 160, height: 90)
        let before = ShotCameraFrame.make(settings: settings, track: track(), flight: nil, size: size, time: 0.04)
        let fading = ShotCameraFrame.make(settings: settings, track: track(), flight: nil, size: size, time: 0.3)
        let lost = ShotCameraFrame.make(settings: settings, track: track(), flight: nil, size: size, time: 0.6)
        XCTAssertGreaterThan(before.uniforms.crop.z, fading.uniforms.crop.z)
        XCTAssertGreaterThan(fading.uniforms.crop.z, 1)
        XCTAssertFalse(lost.isActive, "Never keep following an invented position through a long gap")
    }

    func testImpactAndMagnifierNeedSupportAtTheMarkedStrike() {
        for style in [ShotCameraStyle.impact, .lens] {
            let unsupported = ShotCameraFrame.make(settings: .init(style: style, strike: 1),
                track: track(), flight: nil, size: CGSize(width: 160, height: 90), time: 1)
            XCTAssertFalse(unsupported.isActive)
        }
    }

    func testRotatedCropNeverReadsOutsidePortraitOrLandscapeVideo() {
        for size in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)] {
            let frame = ShotCameraFrame.make(settings: .init(style: .tilt, strength: 1.4, strike: 0.04),
                                             track: track(), flight: nil, size: size, time: 0.04)
            let crop = frame.uniforms.crop, c = cos(Double(crop.w)), s = sin(Double(crop.w))
            for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
                let x = (corner.x - size.width / 2) / Double(crop.z)
                let y = (corner.y - size.height / 2) / Double(crop.z)
                let sourceX = (c * x + s * y) / size.width + Double(crop.x)
                let sourceY = (-s * x + c * y) / size.height + Double(crop.y)
                XCTAssertGreaterThanOrEqual(sourceX, -0.00001); XCTAssertLessThanOrEqual(sourceX, 1.00001)
                XCTAssertGreaterThanOrEqual(sourceY, -0.00001); XCTAssertLessThanOrEqual(sourceY, 1.00001)
            }
        }
    }

    func testFreezePathBreaksAtAnOcclusion() {
        let found = track(times: [0, 0.02, 0.04, 1, 1.02, 1.04])
        let frame = ShotCameraFrame.make(settings: .init(style: .freeze, strike: 0),
                                         track: found, flight: nil, size: CGSize(width: 160, height: 90), time: 0)
        XCTAssertEqual(frame.path.count, 6)
        XCTAssertEqual(frame.path[3].z, 0, "The path must not bridge the missing second")
    }

    func testGPUFollowMovesTheOriginalPixelsAndLensMagnifiesThem() throws {
        let engine = try MetalEffectEngine()
        let source = try engine.texture(width: 160, height: 90, storage: .shared)
        var bytes = [UInt8](repeating: 0, count: 160 * 90 * 4)
        for y in 0..<90 { for x in 0..<160 {
            let i = (y * 160 + x) * 4
            let white = abs(x - 120) < 4 && abs(y - 54) < 4
            bytes[i] = white ? 255 : 100; bytes[i + 1] = white ? 255 : 40
            bytes[i + 2] = white ? 255 : 20; bytes[i + 3] = 255
        }}
        bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 640) }
        let target = try engine.texture(width: 160, height: 90, storage: .shared)
        let size = CGSize(width: 160, height: 90)
        let original = EffectFrame.shot(size: size, sourceSize: size, style: .none, intensity: 0, track: track(), time: 0.04)
        for style in [ShotCameraStyle.follow, .lens] {
            let camera = ShotCameraFrame.make(settings: .init(style: style, strike: 0.04), track: track(), flight: nil, size: size, time: 0.04)
            try engine.render(original, into: target, source: source, camera: camera)
            var output = bytes
            output.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 640, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0) }
            let white = (0..<(160 * 90)).filter { i in output[i * 4] > 240 && output[i * 4 + 1] > 240 && output[i * 4 + 2] > 240 }
            XCTAssertGreaterThan(white.count, 49)
            if style == .follow {
                let center = Double(white.map { $0 % 160 }.reduce(0, +)) / Double(white.count)
                XCTAssertLessThan(center, 100, "The ball's source pixels move toward the centre")
                XCTAssertGreaterThan(center, 70)
            } else {
                XCTAssertTrue(white.contains { $0 % 160 > 110 && $0 / 160 < 45 }, "The contact pixels are magnified in the inset")
            }
        }
    }
}
