import CoreGraphics
import Foundation
import Metal
import Testing
@testable import kicklab

struct MetalEffectsTests {
    @Test func noneBypassesPreviouslyRenderedFireAtTheSameTimestamp() throws {
        let engine=try MetalEffectEngine()
        let source=try engine.texture(width:192,height:256,storage:.shared)
        let target=try engine.texture(width:192,height:256,storage:.shared)
        var pixels=[UInt8](repeating:71,count:192*256*4)
        for i in stride(from:3,to:pixels.count,by:4) {pixels[i]=255}
        pixels.withUnsafeBytes {source.replace(region:MTLRegionMake2D(0,0,192,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:192*4)}
        var frame=base()
        try engine.render(frame,into:target,source:source)
        #expect(read(target) != pixels)
        // Intensity and trail deliberately remain: None alone must be enough.
        frame.style=BallStyle.none.shaderID
        try engine.render(frame,into:target,source:source)
        #expect(read(target)==pixels)
        try engine.render(frame,into:target)
        #expect(read(target).allSatisfy {$0==0})
        frame.style=BallStyle.fire.shaderID
        try engine.render(frame,into:target,source:source)
        #expect(read(target) != pixels)
    }
    private func base() -> EffectFrame {
        EffectFrame(size: CGSize(width: 192, height: 256), center: SIMD2(96, 168), radius: 17,
                    time: 1.25, intensity: 0.85)
    }
    private func read(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }
    private func energy(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) + Int(bytes[$1+1]) + Int(bytes[$1+2]) }
    }

    @Test func gpuRenderingPausesSeeksAndClearsCorrectly() throws {
        #expect(MemoryLayout<EffectUniforms>.stride == 112)
        let engine = try MetalEffectEngine()
        let target = try engine.texture(width: 192, height: 256, storage: .shared)
        var frame = base()
        try engine.render(frame, into: target)
        let fire = read(target)
        #expect(energy(fire) > 10_000)
        try engine.render(frame, into: target)
        #expect(read(target) == fire) // paused frame / repeated timestamp
        frame.time = 1.75
        try engine.render(frame, into: target)
        #expect(read(target) != fire)
        frame.time = 1.25 // seeking backwards restores the exact flame
        try engine.render(frame, into: target)
        #expect(read(target) == fire)
        for style: Float in [2, 3, 4, 5, 6, 7, 8, 9, 10] {
            frame.style = style
            try engine.render(frame, into: target)
            let other = read(target)
            #expect(energy(other) > 5_000)
            #expect(other != fire)
        }
        frame.intensity = 0
        try engine.render(frame, into: target)
        #expect(read(target).allSatisfy { $0 == 0 })
        frame.intensity = 1; frame.visibility = 0
        try engine.render(frame, into: target)
        #expect(read(target).allSatisfy { $0 == 0 })
    }

    @Test func everyMaterialHasItsOwnSilhouetteAndClearsOnSeek() throws {
        let engine = try MetalEffectEngine()
        let target = try engine.texture(width: 192, height: 256, storage: .shared)
        var masks: [[Double]] = []
        for style in BallStyle.allCases where style != .none {
            var frame = base(); frame.style = style.shaderID
            frame.trail = (1...32).map { i in
                let age = Float(i) / 40
                return SIMD4(96 - age * 45, 168 - age * 100, 17, age)
            }
            try engine.render(frame, into: target)
            let original = read(target)
            let alpha = stride(from: 3, to: original.count, by: 4).map { Double(original[$0]) }
            let norm = sqrt(alpha.reduce(0) { $0 + $1 * $1 })
            #expect(norm > 100, "Missing material: \(style)")
            masks.append(alpha.map { $0 / max(1, norm) })
            frame.time += 0.2
            try engine.render(frame, into: target)
            #expect(read(target) != original, "Frozen animation: \(style)")
            frame.time -= 0.2
            try engine.render(frame, into: target)
            #expect(read(target) == original, "Seek changed material: \(style)")
            for hidden in [true, false] {
                frame.visibility = hidden ? 0 : 1
                frame.intensity = hidden ? 1 : 0
                try engine.render(frame, into: target)
                #expect(read(target).allSatisfy { $0 == 0 })
            }
        }
        // Compare normalized alpha, not RGB: recoloring one shape cannot pass.
        for i in masks.indices { for j in masks.indices where j > i {
            let similarity = zip(masks[i], masks[j]).reduce(0) { $0 + $1.0 * $1.1 }
            #expect(similarity < 0.97, "Effects \(i + 1) and \(j + 1) share a silhouette")
        } }
    }

    @Test func previewAndVideoCompositeAgreeAndAlphaIsPremultiplied() throws {
        let engine = try MetalEffectEngine()
        let overlay = try engine.texture(width: 192, height: 256, storage: .shared)
        let output = try engine.texture(width: 192, height: 256, storage: .shared)
        let source = try engine.texture(width: 192, height: 256, storage: .shared)
        var background = [UInt8](repeating: 80, count: 192 * 256 * 4)
        for i in stride(from: 3, to: background.count, by: 4) { background[i] = 255 }
        background.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,192,256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 192*4) }
        for style in BallStyle.allCases where style != .none {
            var frame = base(); frame.style = style.shaderID
            try engine.render(frame, into: overlay)
            try engine.render(frame, into: output, source: source)
            let a = read(overlay), b = read(output)
            var largestDifference = 0
            var validAlpha = true
            for i in stride(from: 0, to: a.count, by: 4) {
                for c in 0..<3 {
                    validAlpha = validAlpha && a[i+c] <= a[i+3]
                    let expected = Double(a[i+c]) + 80 * (1 - Double(a[i+3])/255)
                    largestDifference = max(largestDifference, Int(abs(Double(b[i+c]) - expected).rounded()))
                }
            }
            #expect(validAlpha)
            #expect(largestDifference <= 2) // unorm rounding between passes
            #expect(b[3] == 255)
        }
    }

    @Test func fireRefractionPreservesTheTrackedBallButStillWarpsSurroundingAir() throws {
        let engine = try MetalEffectEngine()
        let overlay = try engine.texture(width: 192, height: 256, storage: .shared)
        let output = try engine.texture(width: 192, height: 256, storage: .shared)
        let source = try engine.texture(width: 192, height: 256, storage: .shared)
        var pixels = [UInt8](repeating: 255, count: 192 * 256 * 4)
        for y in 0..<256 { for x in 0..<192 {
            for c in 0..<3 { pixels[(y * 192 + x) * 4 + c] = (x / 2 + y / 2).isMultiple(of: 2) ? 35 : 210 }
        } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 192, 256), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 192 * 4) }
        var frame = base(); frame.radius = 30
        try engine.render(frame, into: overlay)
        try engine.render(frame, into: output, source: source)
        let fx = read(overlay), composite = read(output)
        var ballError = 0.0, airError = 0.0
        for y in 0..<256 { for x in 0..<192 {
            let radius = hypot(Double(x) + 0.5 - Double(frame.center.x), Double(y) + 0.5 - Double(frame.center.y)) / Double(frame.radius)
            let i = (y * 192 + x) * 4
            for c in 0..<3 {
                let expected = Double(fx[i+c]) + Double(pixels[i+c]) * (1 - Double(fx[i+3]) / 255)
                let error = abs(Double(composite[i+c]) - expected)
                if radius <= 1 { ballError = max(ballError, error) }
                if radius > 1.3 && radius < 3 { airError = max(airError, error) }
            }
        } }
        #expect(ballError <= 2)
        #expect(airError > 5)
    }

    @Test func iceLeavesTheBallReadableEvenWhenItsWakeCrossesTheFace() throws {
        let engine = try MetalEffectEngine()
        let source = try engine.texture(width: 192, height: 256, storage: .shared)
        let output = try engine.texture(width: 192, height: 256, storage: .shared)
        let overlay = try engine.texture(width: 192, height: 256, storage: .shared)
        var pixels = [UInt8](repeating: 255, count: 192 * 256 * 4)
        for y in 0..<256 { for x in 0..<192 {
            let i = (y * 192 + x) * 4
            pixels[i] = UInt8((x * 13 + y * 7) % 256)
            pixels[i+1] = UInt8((x * 3 + y * 17) % 256)
            pixels[i+2] = UInt8((x * 11 + y * 5) % 256)
        } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 192, 256), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 192 * 4) }
        var frame = base(); frame.style = BallStyle.ice.shaderID; frame.radius = 25
        frame.trail = (1...32).map { i in
            let age = Float(i) / 40
            return SIMD4(96 + sin(age * 12) * 45, 168 - age * 90, 25, age)
        }
        try engine.render(frame, into: output, source: source)
        try engine.render(frame, into: overlay)
        let result = read(output), frost = read(overlay)
        var coreDifference = 0, blueEnergy = 0, redEnergy = 0
        for y in 0..<256 { for x in 0..<192 {
            let i = (y * 192 + x) * 4
            let r = hypot(Double(x) + 0.5 - 96, Double(y) + 0.5 - 168) / 25
            if r <= 0.9 {
                for c in 0..<3 { coreDifference = max(coreDifference, abs(Int(result[i+c]) - Int(pixels[i+c]))) }
            }
            if r > 1.05 && r < 2 {
                blueEnergy += Int(frost[i]); redEnergy += Int(frost[i+2])
            }
        } }
        #expect(coreDifference <= 1)
        #expect(blueEnergy > 5_000)
        #expect(blueEnergy > redEnergy)
    }

    @Test func neonKeepsTheBallReadableWithEnergyAboveAndBelowIt() throws {
        let engine = try MetalEffectEngine()
        let source = try engine.texture(width: 192, height: 256, storage: .shared)
        let output = try engine.texture(width: 192, height: 256, storage: .shared)
        let overlay = try engine.texture(width: 192, height: 256, storage: .shared)
        var pixels = [UInt8](repeating: 255, count: 192 * 256 * 4)
        for y in 0..<256 { for x in 0..<192 { for c in 0..<3 {
            pixels[(y * 192 + x) * 4 + c] = UInt8((x * 13 + y * 7 + c * 59) % 256)
        } } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 192, 256), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 192 * 4) }
        var frame = base(); frame.style = BallStyle.neon.shaderID; frame.center = SIMD2(96, 128)
        frame.trail = (1...32).map { i in
            let age = Float(i) / 40
            return SIMD4(96 - age * 20, 128, 17, age)
        }
        for time in [1.25, 1.75, 2.3] {
            frame.time = time
            try engine.render(frame, into: output, source: source)
            try engine.render(frame, into: overlay)
            let result = read(output), fx = read(overlay)
            var coreDifference = 0, upperEnergy = 0, lowerEnergy = 0
            for y in 0..<256 { for x in 0..<192 {
                let i = (y * 192 + x) * 4
                let r = hypot(Double(x) + 0.5 - 96, Double(y) + 0.5 - 128) / 17
                if r <= 0.9 {
                    for c in 0..<3 { coreDifference = max(coreDifference, abs(Int(result[i+c]) - Int(pixels[i+c]))) }
                }
                if Double(y) < 128 - 2.5 * 17 { upperEnergy += Int(fx[i+3]) }
                if Double(y) > 128 + 2.5 * 17 { lowerEnergy += Int(fx[i+3]) }
            } }
            #expect(coreDifference <= 1, "Neon must preserve the ball face at \(time)")
            #expect(upperEnergy > 1_000, "Missing upper Neon sweep at \(time)")
            #expect(lowerEnergy > 1_000, "Missing lower Neon wake at \(time)")
        }
    }

    @Test func contactCueUsesTimeWindowsAndRejectsFlightGapsAndJitter() {
        func frame(_ time: Double, _ fps: Int, _ kind: Int = 0) -> EffectFrame {
            func y(_ t: Double) -> Float {
                let d = Float(t-1)
                if kind == 1 { return 160 + d * 260 } // fast, uninterrupted flight
                if kind == 2 { return 160 + abs(d) * 240 } // apex, not a touch
                if kind == 3 { return 160 + sin(Float(t)*70) * 0.7 } // subpixel wobble
                return 160 + (d < 0 ? d*240 : -d*280)
            }
            var f = EffectFrame(size: CGSize(width: 320,height: 320),center: SIMD2(160,y(time)),
                                radius: 20,time: time,intensity: 1,style: 3)
            f.trail = (0...Int(time*Double(fps))).compactMap { i in
                let t = Double(i)/Double(fps), age = Float(time-t)
                guard age > 0,age < 0.8 else { return nil }
                if kind == 4 && t > 0.90 && t < 1.09 { return nil }
                return SIMD4(160,y(t),20,age)
            }
            return f
        }
        for fps in [30,60,120] {
            var f = frame(1.133333333,fps)
            let cue = f.contactMotionCue
            #expect(cue.strength > 0.8)
            #expect(abs(cue.age-Float(0.133333333)) < 0.035)
            f.trail.reverse()
            #expect(f.contactMotionCue.age == cue.age)
            #expect(f.contactMotionCue.strength == cue.strength)
            for kind in [1,2,3,4] { #expect(frame(1.133333333,fps,kind).contactMotionCue.strength == 0) }
            #expect(frame(1.04,fps).contactMotionCue.strength == 0) // not enough post-contact data
            #expect(frame(1.5,fps).contactMotionCue.strength == 0) // burst has expired
        }
        // Exercise the real 60 Hz replay adapter that the old dt>0.02 scan skipped.
        let f = frame(1.133333333,60)
        func sample(_ x: Float,_ y: Float,_ age: Float) -> BallStyleSample {
            var s = BallStyleSample(center: CGPoint(x: Double(x)/320,y: Double(y)/320),radius: 20.0/320,confidence: 0.9)
            s.time = f.time-Double(age); return s
        }
        let current = sample(f.center.x,f.center.y,0)
        let trail = f.trail.map { sample($0.x,$0.y,$0.w) }.sorted { $0.time < $1.time }
        for style: BallStyle in [.neon,.galaxy,.aura,.rainbow] {
            let adapted = EffectFrame.tracked(size: f.size,sourceSize: f.size,style: style,intensity: 1,
                                              sample: current,trail: trail,time: f.time)
            #expect(adapted.impact > 0.8)
            #expect(abs(adapted.impactAge-0.133333333) < 0.035)
        }
    }

    @Test(arguments: [Float(3), Float(8)]) func ribbonHitBrightensThenExpiresWithoutCoveringTheBall(style: Float) throws {
        let engine = try MetalEffectEngine()
        let target = try engine.texture(width: 192,height: 256,storage: .shared)
        var f = base(); f.style = style; f.center = SIMD2(96,128)
        try engine.render(f,into: target)
        let ordinary = read(target)
        f.impact = 1; f.impactAge = 0.11
        try engine.render(f,into: target)
        let hit = read(target)
        #expect(energy(hit) > energy(ordinary)*13/10)
        for y in 0..<256 { for x in 0..<192 {
            if hypot(Double(x)+0.5-96,Double(y)+0.5-128) <= 17*0.9 {
                #expect(hit[(y*192+x)*4+3] == 0)
            }
        } }
        f.impactAge = 0.43
        try engine.render(f,into: target)
        #expect(read(target) == ordinary)
        f.impactAge = 0.11
        try engine.render(f,into: target)
        #expect(read(target) == hit) // seek restores identical burst
    }

    @Test func galaxyAuraAndRainbowProtectBallDetailEvenThroughBrightContactWisps() throws {
        let engine = try MetalEffectEngine()
        let source = try engine.texture(width: 192,height: 256,storage: .shared)
        let target = try engine.texture(width: 192,height: 256,storage: .shared)
        let overlay = try engine.texture(width: 192,height: 256,storage: .shared)
        var pixels = [UInt8](repeating: 255,count: 192*256*4)
        for y in 0..<256 { for x in 0..<192 { for c in 0..<3 {
            pixels[(y*192+x)*4+c] = UInt8((x*13+y*7+c*37)%256)
        } } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,192,256),mipmapLevel: 0,
            withBytes: $0.baseAddress!,bytesPerRow: 192*4) }
        for style: Float in [4,6,8] {
            var f = base(); f.center = SIMD2(96,128); f.style = style; f.impact = 1; f.impactAge = 0.10
            f.trail = (1...32).map { i in
                let age = Float(i)/40
                return SIMD4(96+sin(age*8)*35,128+age*95,17,age)
            }
            try engine.render(f,into: target,source: source)
            try engine.render(f,into: overlay)
            let result = read(target), fx = read(overlay)
            var coreError = 0, outsideEnergy = 0
            for y in 0..<256 { for x in 0..<192 {
                let r = hypot(Double(x)+0.5-96,Double(y)+0.5-128)/17, i = (y*192+x)*4
                if r <= 0.9 {
                    for c in 0..<3 { coreError = max(coreError,abs(Int(result[i+c])-Int(pixels[i+c]))) }
                } else { outsideEnergy += Int(fx[i+3]) }
            } }
            #expect(coreError <= 1)
            #expect(outsideEnergy > 5_000)
        }
    }

    @Test func counterBurstSettlesAndHasDeterministicSeeds() throws {
        let engine = try MetalEffectEngine()
        let target = try engine.texture(width: 192, height: 256, storage: .shared)
        var frame = base()
        frame.center = SIMD2(96, 128); frame.radius = 45
        frame.counter = true; frame.burstAge = 0.14; frame.seed = 24
        try engine.render(frame, into: target)
        let burst = read(target)
        frame.seed = 25
        try engine.render(frame, into: target)
        #expect(read(target) != burst)
        frame.seed = 24
        try engine.render(frame, into: target)
        #expect(read(target) == burst)
        frame.burstAge = 1.2
        try engine.render(frame, into: target)
        #expect(energy(read(target)) < energy(burst) / 2)
    }

    @Test func nightfallWorksWithoutDetectionOrEffectAndPreservesOriginal() throws {
        let engine = try MetalEffectEngine()
        let source = try engine.texture(width: 192, height: 256, storage: .shared)
        let output = try engine.texture(width: 192, height: 256, storage: .shared)
        var bytes = [UInt8](repeating: 180, count: 192 * 256 * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,192,256), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 192*4) }
        var frame = EffectFrame.video(size: CGSize(width: 192, height: 256), sourceSize: CGSize(width: 192, height: 256),
            edit: SessionEditState(style: .none, intensity: 0, environment: .night), track: BallEffectTrack(frames: []), time: 2)
        #expect(frame.visibility == 0)
        try engine.render(frame, into: output, source: source)
        let night = read(output)
        #expect(energy(night) < energy(bytes) / 2)
        let center = (128 * 192 + 96) * 4
        #expect(night[center] > night[center+2]) // BGRA: cooler blue than red
        frame.environment = 0
        try engine.render(frame, into: output, source: source)
        #expect(read(output) == bytes)
    }

    @Test func compositorUsesSameAspectFillGeometryAsTracking() throws {
        let engine = try MetalEffectEngine()
        let source = try engine.texture(width: 100, height: 200, storage: .shared)
        let output = try engine.texture(width: 100, height: 100, storage: .shared)
        var pixels = [UInt8](repeating: 0, count: 100 * 200 * 4)
        for y in 0..<200 { for x in 0..<100 {
            let offset = (y * 100 + x) * 4
            pixels[offset] = UInt8(y); pixels[offset+1] = UInt8(x); pixels[offset+3] = 255
        } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,100,200), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 400) }
        let frame = EffectFrame(size: CGSize(width: 100, height: 100), center: SIMD2(50,50), radius: 1,
            time: 0, intensity: 0, style: 0)
        try engine.render(frame, into: output, source: source)
        let result = read(output)
        #expect(abs(Int(result[0]) - 50) <= 1)
        #expect(abs(Int(result[(99*100)*4]) - 149) <= 1)
        #expect(result[(50*100+50)*4+1] == 50)
    }

    @Test func trackingAdapterUsesCropAndRealHistoryAge() {
        var sample = BallStyleSample(center: CGPoint(x: 0.5, y: 0.6), radius: 0.05, confidence: 0.9)
        sample.time = 2
        var past = sample; past.center.x = 0.48; past.time = 1.9
        let frame = EffectFrame.tracked(size: CGSize(width: 360, height: 400), sourceSize: CGSize(width: 1080, height: 1920),
            style: .fire, intensity: 0.85, sample: sample, trail: [past, sample], time: 2)
        #expect(abs(frame.center.x - 180) < 0.001)
        #expect(abs(frame.center.y - 264) < 0.001)
        #expect(abs(frame.radius - 18) < 0.001)
        #expect(abs(frame.velocity.x - 4) < 0.001)
        #expect(abs(frame.trail[0].w - 0.1) < 0.001)
    }

    @Test func emissionHistoryInterpolatesBirthsAndDoesNotBridgeMissingTracking() {
        var frame = base()
        frame.center = SIMD2(100, 160)
        frame.trail = [SIMD4(80, 160, 17, 0.1), SIMD4(90, 160, 17, 0.05)]
        let history = frame.emissionHistory
        #expect(abs(history[1].x - 95) < 0.001)
        #expect(abs(history[3].x - 85) < 0.001)
        #expect(history[5].w == 0) // beyond available track
        frame.trail = [SIMD4(50, 160, 17, 0.3)]
        #expect(frame.emissionHistory[4].w == 0) // occlusion, not a fabricated path
        frame.trail = []; frame.time = 0.02
        #expect(frame.emissionHistory[1].w == 0) // no births before video begins
    }

    @Test func personDetectionCannotAnchorOrMoveTheEffect() {
        func recorded(_ person: PersonBox?) -> RecordedFrame {
            RecordedFrame(time: 1, x: 0.4, y: 0.7, width: 0.06, height: 0.04, score: 0.9,
                smoothedX: 0.4, smoothedY: 0.7, vy: 0, motion: .unknown, detected: true, person: person)
        }
        let size = CGSize(width: 360, height: 640)
        for style in BallStyle.allCases where style != .none {
            let edit = SessionEditState(style: style, intensity: 0.85)
            let a = EffectFrame.video(size: size, sourceSize: size, edit: edit,
                track: BallEffectTrack(frames: [recorded(nil)]), time: 1)
            let b = EffectFrame.video(size: size, sourceSize: size, edit: edit,
                track: BallEffectTrack(frames: [recorded(PersonBox(x: 0.9, y: 0.3, width: 0.2, height: 0.4))]), time: 1)
            #expect(a == b, "\(style) is anchored to the player instead of the ball")
        }
    }

    @Test func everyEffectMovesWithTheBallAndLeavesMaterialOnItsActualPath() throws {
        let engine = try MetalEffectEngine()
        let target = try engine.texture(width: 320, height: 256, storage: .shared)
        func centerOfLight(_ bytes: [UInt8]) -> Double {
            var weight = 0.0, moment = 0.0
            for y in 0..<256 { for x in 0..<320 {
                let a = Double(bytes[(y*320+x)*4+3])
                weight += a; moment += Double(x)*a
            } }
            return moment / max(weight, 1)
        }
        for style: Float in [1,2,3,4,5,6,7,8,9,10] {
            var frame = EffectFrame(size: CGSize(width: 320, height: 256), center: SIMD2(90, 150),
                radius: 12, time: 2.3, intensity: 0.85, style: style)
            try engine.render(frame, into: target)
            let left = centerOfLight(read(target))
            frame.center.x += 140
            try engine.render(frame, into: target)
            #expect(abs(centerOfLight(read(target)) - left - 140) < 12, "\(style) left its effect behind")
            frame.center = SIMD2(160, 150)
            frame.trail = (1...32).map { i in
                let age = Float(i) / 40
                return SIMD4(160 - age * 100, 150, 12, age)
            }
            try engine.render(frame, into: target)
            let leftPixels = read(target)
            let leftWake = centerOfLight(leftPixels)
            frame.trail = frame.trail.map { SIMD4(320 - $0.x, $0.y, $0.z, $0.w) }
            try engine.render(frame, into: target)
            let rightPixels = read(target)
            if style == 1 {
                // V5 keeps most fire at the current ball. Measure the changed
                // wake itself: mirroring the path must move its light right,
                // without requiring the whole flame's centroid to drift away.
                var changed = 0.0, moment = 0.0
                for y in 0..<256 { for x in 0..<320 {
                    let offset = (y * 320 + x) * 4 + 3
                    let delta = Double(rightPixels[offset]) - Double(leftPixels[offset])
                    changed += abs(delta)
                    moment += delta * Double(x - 160)
                } }
                #expect(changed > 1000, "Fire wake must be visibly present")
                #expect(moment / max(1, changed) > Double(frame.radius) * 0.5,
                        "Fire wake must follow the mirrored recorded path")
                // A caller's ordering is not part of the public frame contract.
                frame.trail.reverse()
                try engine.render(frame, into: target)
                #expect(read(target) == rightPixels)
            } else {
                #expect(centerOfLight(rightPixels) > leftWake + 5, "\(style) ignored the recorded ball path")
            }
        }
    }

    @Test func particleBirthPositionStaysFixedAsTheEmitterMoves() {
        var a = base()
        a.center = SIMD2(100, 160)
        a.trail = (1...32).map { i in
            let age = Float(i) / 40
            return SIMD4(100 - age * 80, 160, 17, age)
        }
        var b = a
        b.time += 0.025; b.center.x += 2
        b.trail = (1...32).map { i in
            let age = Float(i) / 40
            return SIMD4(102 - age * 80, 160, 17, age)
        }
        let birthA = a.emissionHistory[8], birthB = b.emissionHistory[9]
        #expect(abs(birthA.x - birthB.x) < 0.001)
        #expect(abs(birthA.y - birthB.y) < 0.001)
    }

    @Test func fluidRemembersTheActualPathAndChangesContinuously() throws {
        let engine = try MetalEffectEngine()
        let target = try engine.texture(width: 192, height: 256, storage: .shared)
        var frame = base()
        frame.trail = (1...32).map { i in
            let age = Float(i) / 40
            return SIMD4(96 - age * 70, 168, 17, age)
        }
        try engine.render(frame, into: target)
        let left = read(target)
        frame.trail = frame.trail.map { SIMD4(192 - $0.x, $0.y, $0.z, $0.w) }
        try engine.render(frame, into: target)
        let right = read(target)
        #expect(left != right) // same current ball, different emitted trail
        frame.trail = []
        try engine.render(frame, into: target)
        let start = read(target)
        frame.time += 1.0 / 240
        try engine.render(frame, into: target)
        let near = read(target)
        frame.time += 0.25
        try engine.render(frame, into: target)
        let far = read(target)
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
            zip(a,b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        #expect(difference(start, near) < difference(start, far))
    }
}
