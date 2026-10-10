import CoreGraphics
import CoreVideo
import simd
import XCTest
@testable import kicklab

/// The replacement takes the scene's light colour from the real ball's white panels.
final class BallLightMatchTests: XCTestCase {
    private func timeline(_ whites: [SIMD3<Float>?], step: Double = 0.1) -> BallSurfaceTimeline {
        BallSurfaceTimeline(entries: whites.enumerated().map { i, w in
            .init(time: Double(i)*step, orientation: BallSurfaceTimeline.initial, accepted: true, white: w)
        }, elapsed: 0)
    }

    func testLightIsAMedianWithinHalfASecond() throws {
        var whites = [SIMD3<Float>?](repeating: SIMD3(240, 230, 200), count: 21)
        whites[10] = SIMD3(40, 40, 255)   // one mis-measured frame must not tint the ball
        let light = try XCTUnwrap(timeline(whites).light(at: 1.0))
        XCTAssertEqual(light, SIMD3(240, 230, 200))
        let sparse = timeline([SIMD3(240, 230, 200), nil, nil, nil, SIMD3(240, 230, 200), nil, nil, nil, nil, nil], step: 0.2)
        XCTAssertNil(sparse.light(at: 0.8), "Fewer than five measured frames: leave the material unchanged")
    }

    func testWarmLightWarmsRedNotBlue() throws {
        let size = CGSize(width: 720, height: 1280)
        let f = BallReplacementFootprint(sourceSize: size, center: CGPoint(x: 360, y: 640), radius: 50,
                                         radii: Array(repeating: 50, count: 64), feather: 1, padding: 0)
        let coverage: (Double, Double) -> Double = { x, y in hypot(x-360, y-640) < 49 ? 1 : 0 }
        func mean(_ light: SIMD3<Float>?) throws -> SIMD3<Double> {
            let r = try XCTUnwrap(BallMaterialRenderer.replacement(footprint: f, skin: .classic, time: 1, coverage: coverage,
                orientation: BallSurfaceTimeline.initial, light: light))
            let bytes = [UInt8](r.image.dataProvider!.data! as Data)
            var sum = SIMD3<Double>.zero, n = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i+3] == 255 {
                sum += SIMD3(Double(bytes[i+2]), Double(bytes[i+1]), Double(bytes[i]))   // BGRA in memory
                n += 1
            }
            return sum/n
        }
        let neutral = try mean(nil), warm = try mean(SIMD3(255, 228, 170))
        XCTAssertGreaterThan(warm.x/neutral.x, warm.z/neutral.z+0.15, "Warm light raises red relative to blue")
        let same = try mean(SIMD3(228, 228, 228))
        XCTAssertEqual(same.x, neutral.x, accuracy: 0.6); XCTAssertEqual(same.z, neutral.z, accuracy: 0.6)
    }

    func testLightChangesColourNeverCoverage() throws {
        let size = CGSize(width: 720, height: 1280)
        let f = BallReplacementFootprint(sourceSize: size, center: CGPoint(x: 360, y: 640), radius: 50,
                                         radii: Array(repeating: 50, count: 64), feather: 1.5, padding: 0)
        let coverage: (Double, Double) -> Double = { x, y in max(0, min(1, 50.5-hypot(x-360, y-640))) * (x > 380 && y < 630 ? 0 : 1) }
        func alpha(_ light: SIMD3<Float>?) throws -> [UInt8] {
            let r = try XCTUnwrap(BallMaterialRenderer.replacement(footprint: f, skin: .classic, time: 1, coverage: coverage,
                orientation: BallSurfaceTimeline.initial, smear: CGVector(dx: 4, dy: 3), light: light))
            return stride(from: 3, to: (r.image.dataProvider!.data! as Data).count, by: 4).map { [UInt8](r.image.dataProvider!.data! as Data)[$0] }
        }
        XCTAssertEqual(try alpha(nil), try alpha(SIMD3(255, 228, 170)), "Light match must not move the outline or cut-outs")
    }

    func testWhiteEstimateReadsNeutralPanelsNotColouredPrint() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 200, 200, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<200 { for x in 0..<200 {
            let p = base+y*stride+x*4
            // Left half warm-white panel, right half saturated yellow print.
            let rgb: (UInt8, UInt8, UInt8) = x < 100 ? (240, 230, 200) : (250, 235, 40)
            p[0] = rgb.2; p[1] = rgb.1; p[2] = rgb.0; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let white = try XCTUnwrap(BallSurfaceTimeline.white(pixels: pixels, center: CGPoint(x: 100, y: 100), radius: 80))
        XCTAssertEqual(white.x, 240, accuracy: 1); XCTAssertEqual(white.y, 230, accuracy: 1); XCTAssertEqual(white.z, 200, accuracy: 1)
    }
}
