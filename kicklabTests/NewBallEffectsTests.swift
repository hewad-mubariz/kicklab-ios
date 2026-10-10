import CoreGraphics
import Foundation
import Metal
import Testing
@testable import kicklab

struct NewBallEffectsTests {
    static let styles: [BallStyle] = [.labFlame, .glowTrail, .blueFlame, .emberWake, .flameRibbon, .heatPulse]

    private func observation(_ time: Double, x: Double = 0.5, y: Double = 0.5) -> RecordedFrame {
        .init(time: time, x: x, y: y, width: 0.15, height: 0.15, score: 0.9,
              smoothedX: x, smoothedY: y, vy: 0, motion: .unknown, detected: true, person: nil)
    }

    @Test func heatPulseUsesConfirmedEventsAndRewindsWithoutInventingTouches() {
        let frames = (0...120).map { i in
            observation(Double(i) / 60, y: 0.5 + sin(Double(i) / 8) * 0.15)
        }
        let track = BallEffectTrack(frames: frames, touchTimes: [1.5, .nan, -1, 0.6, .infinity])
        let empty = BallEffectTrack(frames: frames)
        func effect(_ track: BallEffectTrack, _ time: Double) -> EffectFrame {
            .video(size: CGSize(width: 256, height: 256), sourceSize: CGSize(width: 256, height: 256),
                   edit: .init(style: .heatPulse, intensity: 0.85), track: track, time: time)
        }
        #expect(effect(empty, 0.8).impact == 0)
        #expect(effect(track, 0.59).impactAge == -1)
        #expect(effect(track, 0.6).impactAge == 0)
        #expect(abs(effect(track, 0.78).impactAge - 0.18) < 0.0001)
        #expect(effect(track, 1.3).impact == 0)
        #expect(abs(effect(track, 1.6).impactAge - 0.1) < 0.0001)
        #expect(abs(effect(track, 0.78).impactAge - 0.18) < 0.0001)
        #expect(track.latestTouch(at: .nan) == nil)
        let gap = BallEffectTrack(frames: [observation(0), observation(1)], touchTimes: [0.5])
        #expect(effect(gap, 0.6).visibility == 0)
    }

    @Test(arguments: Self.styles)
    func newEffectsKeepTheBallFaceClearAndFollowBothTravelDirections(style: BallStyle) throws {
        let engine = try MetalEffectEngine()
        let texture = try engine.texture(width: 320, height: 256, storage: .shared)
        var frame = EffectFrame(size: CGSize(width: 320, height: 256), center: SIMD2(160, 128),
                                radius: 20, time: 2.35, intensity: 0.85, impact: 1,
                                impactAge: 0.18, style: style.shaderID)
        for sign: Float in [-1, 1] {
            frame.velocity = SIMD2(sign * 9, 0)
            frame.trail = (1...32).map { i in
                let age = Float(i) / 40
                return SIMD4(160 - sign * 9 * 20 * age, 128, 20, age)
            }
            try engine.render(frame, into: texture)
            var pixels = [UInt8](repeating: 0, count: 320 * 256 * 4)
            pixels.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: 320 * 4,
                    from: MTLRegionMake2D(0, 0, 320, 256), mipmapLevel: 0)
            }
            var left = 0, right = 0, core = 0
            for y in 0..<256 { for x in 0..<320 {
                let alpha = Int(pixels[(y * 320 + x) * 4 + 3])
                if hypot(Double(x) + 0.5 - 160, Double(y) + 0.5 - 128) < 18 { core = max(core, alpha) }
                if x < 120 { left += alpha }
                if x > 200 { right += alpha }
            } }
            #expect(core == 0, "Ball face must remain clear for \(style)")
            #expect(sign > 0 ? left > right + 200 : right > left + 200,
                    "\(style) must follow the recorded direction, including the touch origin")
        }
    }

    @Test func pulseRingsNeedAnEventAndClearAfterTheirEnvelope() throws {
        let engine = try MetalEffectEngine()
        let texture = try engine.texture(width: 256, height: 256, storage: .shared)
        var frame = EffectFrame(size: CGSize(width: 256, height: 256), center: SIMD2(128, 128),
                                radius: 22, time: 1.5, intensity: 0.85, style: BallStyle.heatPulse.shaderID)
        func distantEnergy() throws -> Int {
            try engine.render(frame, into: texture)
            var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: 256 * 4,
                    from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
            }
            var sum = 0
            for y in 0..<256 { for x in 0..<256 where hypot(Double(x - 128), Double(y - 128)) > 37 {
                sum += Int(bytes[(y * 256 + x) * 4 + 3])
            } }
            return sum
        }
        let idle = try distantEnergy()
        frame.impact = 1; frame.impactAge = 0.28
        #expect(try distantEnergy() > idle + 5_000)
        frame.impactAge = 0.61
        #expect(try distantEnergy() == idle)
        frame.impactAge = -1
        #expect(try distantEnergy() == idle)
    }
}
