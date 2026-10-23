import CoreGraphics
import CoreVideo
import XCTest
@testable import kicklab

final class BallReplacementBackgroundTests: XCTestCase {
    private func matte(occluded: Bool = false) -> BallReplacementCoverage {
        let binary = (0..<(128 * 128)).map { i -> UInt8 in
            let x = Double(i % 128) + 0.5 - 64, y = Double(i / 128) + 0.5 - 64
            return hypot(x, y) < 50 && !(occluded && x > 25 && abs(y) < 10) ? 255 : 0
        }
        let mask = BallMask(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), width: 128, height: 128,
            alpha: BallMask.featheredCoverage(binary, width: 128, height: 128))
        let fitted = BallReplacementFootprint(sourceSize: CGSize(width: 256, height: 256), center: CGPoint(x: 128, y: 128),
            radius: 50, radii: Array(repeating: 50, count: 64), feather: 1, padding: 0)
        return BallReplacementCoverage(mask: mask, fitted: fitted, size: fitted.sourceSize, smear: CGVector(dx: 0, dy: 18))
    }

    private func pixels(matte: BallReplacementCoverage, textured: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<256 { for x in 0..<256 {
            let a = matte.coverage(x: Double(x) + 0.5, y: Double(y) + 0.5)
            let bg = textured ? Double((x * 73 + y * 131) % 180 + 30) : 80
            let p = bytes + y * stride + x * 4
            for c in 0..<3 { p[c] = UInt8((a * 235 + (1 - a) * bg).rounded()) }
            p[3] = 255
        } }
        return pixels
    }

    func testKnownFlatBackgroundReducesOldBallColourWithoutChangingOpaqueBody() throws {
        let m = matte(), source = try pixels(matte: m)
        let background = try XCTUnwrap(BallReplacementBackground(pixels: source, matte: m))
        func patch(_ estimate: BallReplacementBackground?) throws -> BallMaterialRenderer.Replacement {
            try XCTUnwrap(BallMaterialRenderer.replacement(footprint: m.footprint, skin: .stealth, time: 0,
                coverage: { m.coverage(x: $0, y: $1) }, coverageBounds: m.bounds,
                smear: CGVector(dx: 0, dy: 18), background: estimate))
        }
        let old = try patch(nil), fixed = try patch(background)
        let before = Array(try XCTUnwrap(old.image.dataProvider?.data) as Data)
        let after = Array(try XCTUnwrap(fixed.image.dataProvider?.data) as Data)
        XCTAssertEqual(old.image.width, fixed.image.width)
        var oldError = 0.0, newError = 0.0, edgePixels = 0
        for i in 0..<(old.image.width * old.image.height) {
            let a = Double(before[i * 4 + 3]) / 255, opacity = Double(after[i * 4 + 3]) / 255
            if a == 0 || a == 1 {
                XCTAssertEqual(Array(before[i * 4..<i * 4 + 4]), Array(after[i * 4..<i * 4 + 4]))
            }
            guard a > 0.1, a < 0.9 else { continue }
            let source = a * 235 + (1 - a) * 80
            for c in 0..<3 {
                let desired = Double(before[i * 4 + c]) + (1 - a) * 80
                oldError += abs(Double(before[i * 4 + c]) + (1 - a) * source - desired)
                newError += abs(Double(after[i * 4 + c]) + (1 - opacity) * source - desired)
            }
            edgePixels += 1
        }
        XCTAssertGreaterThan(edgePixels, 100)
        XCTAssertLessThan(newError, oldError * 0.35)
    }

    func testTextureAndForegroundCutsDoNotSupplyBackground() throws {
        let m = matte(), noisy = try pixels(matte: m, textured: true)
        let background = try XCTUnwrap(BallReplacementBackground(pixels: noisy, matte: m))
        for i in 0..<64 {
            let a = Double(i) * 2 * .pi / 64
            XCTAssertNil(background.estimate(x: 128 + cos(a) * 51, y: 128 + sin(a) * 51))
        }
        let cut = matte(occluded: true), flat = try pixels(matte: cut)
        let estimate = try XCTUnwrap(BallReplacementBackground(pixels: flat, matte: cut))
        XCTAssertNil(estimate.estimate(x: 174, y: 128), "A finger cutout must not be reconstructed as background")
        XCTAssertNil(estimate.estimate(x: 128, y: 128), "The opaque body never needs background reconstruction")
    }
}
