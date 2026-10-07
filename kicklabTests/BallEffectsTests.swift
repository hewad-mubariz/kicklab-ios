import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import kicklab

struct BallEffectsTests {
    private func frame(_ time: Double, x: Double = 0.5, y: Double = 0.6) -> RecordedFrame {
        RecordedFrame(time: time, x: x, y: y, width: 0.1, height: 0.05625, score: 0.3,
                      smoothedX: 0.1, smoothedY: 0.2, vy: 0, motion: .unknown, detected: true, person: nil)
    }

    @Test func aspectFillUsesVideoCrop() {
        let rect = EffectVideoGeometry.aspectFillRect(source: CGSize(width: 1080, height: 1920), destination: CGSize(width: 360, height: 400))
        #expect(abs(rect.width - 360) < 0.001)
        #expect(abs(rect.height - 640) < 0.001)
        #expect(abs(rect.minY + 120) < 0.001)
    }

    @Test func portraitBallRadiusUsesPhysicalPixels() {
        let sample = BallStyleSample(frame: frame(0))
        #expect(abs(sample.pixelRadius(in: CGSize(width: 1080, height: 1920)) - 54) < 0.001)
        #expect(sample.center == CGPoint(x: 0.5, y: 0.6)) // not the counter's shifted coordinates
    }

    @Test func interpolationDoesNotLagOrBridgeOcclusions() {
        let track = BallEffectTrack(frames: [frame(0, x: 0.4), frame(0.04, x: 0.5), frame(0.8, x: 0.7)])
        #expect(abs((track.sample(at: 0.02)?.center.x ?? 0) - 0.45) < 0.001)
        #expect(track.sample(at: 0.4) == nil)
        #expect(track.sample(at: 1) == nil)
        #expect(track.sample(at: -0.2) == nil)
    }

    @Test func materialAloneCountsAsAnEdit() {
        #expect(SessionEditState(style: .none, intensity: 0, ballSkin: .gold).isEdited)
        #expect(!SessionEditState(style: .none, intensity: 0, ballSkin: .original).isEdited)
        #expect(!SessionEditState(style: .fire, intensity: 0, ballSkin: .original).isEdited)
    }

    @Test func reacquisitionCannotJoinAnOldTrailOrInventVelocity() {
        let track = BallEffectTrack(frames: [frame(0, x: 0.1), frame(0.04, x: 0.2),
                                            frame(0.35, x: 0.8), frame(0.39, x: 0.82)])
        #expect(track.trail(at: 0.2).isEmpty)
        #expect(track.trail(at: 0.36).allSatisfy { $0.time >= 0.35 && $0.center.x >= 0.8 })
        let effect = EffectFrame.video(size: CGSize(width: 360, height: 640),
            sourceSize: CGSize(width: 720, height: 1280),
            edit: SessionEditState(style: .fire, intensity: 1), track: track, time: 0.35)
        #expect(effect.velocity == .zero)
    }

    @Test func teleportStartsFreshTrailEvenWithSmallTimeGap() {
        let track = BallEffectTrack(frames: [frame(0, x: 0.1), frame(0.033, x: 0.8)])
        #expect(track.trail(at: 0.033).allSatisfy { $0.center.x == 0.8 })
        #expect(track.sample(at: -0.001) == nil)
        #expect(track.sample(at: .nan) == nil)
    }

    private func render(_ skin: BallSkin, _ time: Double) -> Data {
        let width = 200, height = 320
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        BallMaterialRenderer.draw(in: ctx, size: CGSize(width: width, height: height), sourceSize: CGSize(width: width, height: height),
            skin: skin, sample: BallStyleSample(frame: frame(time)), time: time)
        return Data(bytes: ctx.data!, count: width * height * 4)
    }

    @Test func ballMaterialsRemainDistinctAndOriginalIsTransparent() {
        #expect(render(.gold, 1.25) == render(.gold, 1.25))
        #expect(render(.gold, 1.25) != render(.chrome, 1.25))
        #expect(render(.original, 1.25).allSatisfy { $0 == 0 })
        #expect(render(.gold, 1.25).contains { $0 != 0 })
    }

    @Test func localRefinementFindsBallInsteadOfNeighboringLeg() {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 240, 320, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<320 { for x in 0..<240 {
            let p = bytes + y * stride + x * 4
            let inBall = hypot(Double(x - 100), Double(y - 180)) <= 18
            let inLeg = x > 120 && x < 150 && y > 100 && y < 170
            p[0] = inBall ? 230 : (inLeg ? 15 : 40)
            p[1] = inBall ? 235 : (inLeg ? 15 : 90)
            p[2] = inBall ? 240 : (inLeg ? 15 : 30)
            p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var refiner = BallVisualRefiner()
        let original = Detection(score: 0.2, x: 116.0 / 240, y: 163.0 / 320, width: 50.0 / 240, height: 64.0 / 320)
        let result = refiner.refine(original, in: pixels)
        #expect(hypot(result.x * 240 - 100, result.y * 320 - 180) < 3)
        #expect(abs(result.width * 240 - 36) < 5)
    }

    @Test func patternedBallKeepsItsOuterEdgeThroughMotionAndReacquisition() {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 240, 320, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = buffer!
        var refiner = BallVisualRefiner()
        // An off-centre white panel is brighter than the silhouette. Repeated
        // frames used to shrink the radius prior onto that panel permanently.
        for n in 0..<24 {
            let cx = 110, cy = n < 12 ? 180 - n * 3 : 147 + (n - 11) * 3
            CVPixelBufferLockBaseAddress(pixels, [])
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<320 { for x in 0..<240 {
                let inBall = hypot(Double(x - cx), Double(y - cy)) <= 26
                let inPanel = hypot(Double(x - cx - 6), Double(y - cy + 3)) <= 17
                let value: UInt8 = inBall ? (inPanel ? 245 : 80) : 40
                let p = bytes + y * stride + x * 4
                p[0] = value; p[1] = value; p[2] = value; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let original = Detection(score: 0.2, x: Double(cx) / 240, y: Double(cy) / 320,
                                     width: 52.0 / 240, height: 64.0 / 320)
            let time = Double(n) / 60 + (n >= 20 ? 1 : 0)
            let refined = refiner.refine(original, in: pixels, at: time)
            #expect(hypot(refined.x * 240 - Double(cx), refined.y * 320 - Double(cy)) < 3)
            #expect(abs(refined.width * 240 / 2 - 26) < 3)
        }
    }

    @Test func missingSourceFailsInsteadOfReturningOriginal() async {
        do {
            _ = try await BallStyleBurnIn.render(source: URL(fileURLWithPath: "/missing-kicklab-test.mp4"), track: [],
                                                style: .fire, intensity: 0.8)
            Issue.record("Export unexpectedly succeeded without a video")
        } catch { /* A failed edited export must remain an error. */ }
    }

    private func replacementSource(uniform: Bool = false) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 180, 260, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<260 { for x in 0..<180 {
            let ball = !uniform && hypot(Double(x)-83.5, Double(y)-154.5) <= 26
            let panel = hypot(Double(x)-88, Double(y)-150) < 16
            let value: UInt8 = ball ? (panel ? 240 : 95) : 35
            let p = bytes+y*stride+x*4
            p[0] = value; p[1] = value; p[2] = value; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private var replacementSample: BallStyleSample {
        var sample = BallStyleSample(center: CGPoint(x: 81.5/180, y: 153.0/260), radius: 24.0/180,
            confidence: 0.7, velocityY: 0)
        sample.boxSize = CGSize(width: 48.0/180, height: 48.0/260)
        sample.time = 1
        return sample
    }

    @Test func replacementCoversPatternedBallWithoutGrowingIntoBackground() throws {
        let f = try #require(BallReplacementFootprint.fit(pixels: replacementSource(), sample: replacementSample))
        let patch = try #require(BallMaterialRenderer.replacement(footprint: f, skin: .gold, time: 1))
        // Check the real object's perimeter, not the fitted geometry itself.
        for i in 0..<48 {
            let angle = Double(i)*2 * .pi/48
            let dx = 83.5+25.5*cos(angle)-f.center.x, dy = 154.5+25.5*sin(angle)-f.center.y
            #expect(f.edge(at: atan2(dy,dx))+f.padding-f.feather*0.5 >= hypot(dx,dy))
        }
        #expect(patch.rect.width*180 < 64)
        #expect(patch.rect.height*260 < 64)
        #expect(patch.image.width <= 256 && patch.image.height <= 256)
        let data = try #require(patch.image.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)!
        #expect(bytes[3] == 0) // Outside coverage stays transparent.
        #expect(BallMaterialRenderer.replacement(footprint: f, skin: .original, time: 1) == nil)
    }

    @Test func replacementStillAndVideoUseSameOrientationAndSeekResult() throws {
        let pixels = replacementSource()
        let a = try #require(BallReplacementFootprint.fit(pixels: pixels, sample: replacementSample))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 180, height: 260,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let image = try #require(context.makeImage())
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        let b = try #require(BallReplacementFootprint.fit(image: image, sample: replacementSample))
        #expect(a.center == b.center)
        #expect(a.radii == b.radii)
        let first = try #require(BallMaterialRenderer.replacement(footprint: a, skin: .gold, time: 1))
        _ = BallMaterialRenderer.replacement(footprint: b, skin: .gold, time: 8)
        let seekBack = try #require(BallMaterialRenderer.replacement(footprint: b, skin: .gold, time: 1))
        #expect(first.image.dataProvider?.data == seekBack.image.dataProvider?.data)
    }

    @Test func replacementRejectsUninformativePixelsAndInvalidObservations() {
        #expect(BallReplacementFootprint.fit(pixels: replacementSource(uniform: true), sample: replacementSample) == nil)
        var invalid = replacementSample
        invalid.center.x = .nan
        #expect(BallReplacementFootprint.fit(pixels: replacementSource(), sample: invalid) == nil)
        invalid = replacementSample
        invalid.confidence = 0
        #expect(BallReplacementFootprint.fit(pixels: replacementSource(), sample: invalid) == nil)
    }

    @Test func replacementRecoversOffsetOuterEdgeInsteadOfPrintedPanel() throws {
        var sample = replacementSample
        sample.center = CGPoint(x: 81.5/180, y: 174.0/260)
        let fit = try #require(BallReplacementFootprint.fit(pixels: replacementSource(), sample: sample))
        #expect(hypot(fit.center.x-83.5, fit.center.y-154.5) < 2)
        #expect(abs(fit.radius-26) < 2)
    }

    @Test func replacementGuideBridgesOnlyBoundedGapsWithoutChangingEffects() throws {
        let track = BallEffectTrack(frames: [frame(0, x: 0.4), frame(0.16, x: 0.44)])
        #expect(track.sample(at: 0.08) == nil)
        let guide = try #require(track.replacementGuide(at: 0.08))
        #expect(abs(guide.center.x-0.42) < 0.001)
        #expect(guide.visibility == 1)
        #expect(track.replacementGuide(at: -0.001) == nil)
        #expect(track.replacementGuide(at: 0.18) == nil)
        #expect(track.replacementGuide(at: .nan) == nil)
        let long = BallEffectTrack(frames: [frame(0), frame(0.4)])
        #expect(long.replacementGuide(at: 0.2) == nil)
        let jump = BallEffectTrack(frames: [frame(0, x: 0.1), frame(0.16, x: 0.8)])
        #expect(jump.replacementGuide(at: 0.08) == nil)
        // A guide alone is not enough to draw over an occlusion.
        #expect(BallReplacementFootprint.fit(pixels: replacementSource(uniform: true), sample: guide) == nil)
    }

    @Test func replacementRejectsIsolatedPositionSpikeBeforeInterpolation() throws {
        let track = BallEffectTrack(frames: [frame(0, x: 0.4), frame(0.02, x: 0.52), frame(0.04, x: 0.41)])
        #expect(track.sample(at: 0.02)?.center.x == 0.52)
        let corrected = try #require(track.replacementGuide(at: 0.02))
        #expect(abs(corrected.center.x-0.405) < 0.001)
        let interpolated = try #require(track.replacementGuide(at: 0.03))
        #expect(abs(interpolated.center.x-0.4075) < 0.001)
        let moving = BallEffectTrack(frames: [frame(0, x: 0.2), frame(0.02, x: 0.4), frame(0.04, x: 0.6)])
        #expect(moving.replacementGuide(at: 0.02)?.center.x == 0.4)
        // Seek order never changes a prepared position.
        _ = track.replacementGuide(at: 0.04)
        #expect(track.replacementGuide(at: 0.02)?.center == corrected.center)
    }

    @Test func replacementOutlineScalesWithDecodedResolution() throws {
        let pixels = replacementSource()
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let ctx = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 180, height: 260,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let image = try #require(ctx.makeImage())
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        let large = try #require(CGContext(data: nil, width: 720, height: 1040, bitsPerComponent: 8,
            bytesPerRow: 720*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        large.interpolationQuality = .none
        large.draw(image, in: CGRect(x: 0, y: 0, width: 720, height: 1040))
        let a = try #require(BallReplacementFootprint.fit(image: image, sample: replacementSample))
        let largeImage = try #require(large.makeImage())
        let b = try #require(BallReplacementFootprint.fit(image: largeImage, sample: replacementSample))
        #expect(hypot(a.center.x-b.center.x/4, a.center.y-b.center.y/4) < 1.5)
        for i in 0..<a.radii.count {
            #expect(abs(a.radii[i]+a.padding-(b.radii[i]+b.padding)/4) < 2)
        }
    }

    @Test func everyCatalogSkinHasDistinctBundledArtwork() throws {
        let styles = BallSkin.allCases.filter { $0 != .original }
        #expect(styles.count == 10)
        var rasters = Set<Data>()
        for skin in styles {
            #expect(BallSkinSphereRenderer.hasArtwork(for: skin), "Missing bundled texture: \(skin.title)")
            let image = try #require(BallSkinSphereRenderer.image(skin: skin, time: 1.4))
            let data = try #require(image.dataProvider?.data)
            rasters.insert(data as Data)
            let bytes = CFDataGetBytePtr(data)!
            #expect(bytes[3] == 0) // Material image has no rectangular backdrop.
            #expect(bytes[((image.height/2)*image.width+image.width/2)*4+3] == 255)
        }
        #expect(rasters.count == 10)
        #expect(BallSkinSphereRenderer.decodedArtworkBytes <= 6*1024*1024)
        #expect(BallSkinSphereRenderer.image(skin: .original, time: 1.4) == nil)
        // Previous selection IDs still resolve to the new material designs.
        #expect(BallSkin(rawValue: "gold")?.title == "Gold Elite")
        #expect(BallSkin(rawValue: "matrix")?.title == "Neon Circuit")
    }

    @Test func texturedSphereRotatesDeterministicallyAndHasPremultipliedEdges() throws {
        let first = try #require(BallSkinSphereRenderer.image(skin: .gold, time: 1.4))
        let later = try #require(BallSkinSphereRenderer.image(skin: .gold, time: 2.4))
        let seekBack = try #require(BallSkinSphereRenderer.image(skin: .gold, time: 1.4))
        #expect(first.dataProvider?.data != later.dataProvider?.data)
        #expect(first.dataProvider?.data == seekBack.dataProvider?.data)
        let data = try #require(first.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)!
        for i in stride(from: 0, to: CFDataGetLength(data), by: 4) {
            #expect(bytes[i] <= bytes[i+3] && bytes[i+1] <= bytes[i+3] && bytes[i+2] <= bytes[i+3])
        }
        #expect(BallSkinSphereRenderer.image(skin: .gold, time: .nan) == nil)
    }
}
