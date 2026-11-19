import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import kicklab

/// Smoke test for the 2026-11-19 lab bridge: every bridged effect draws a picker icon and every
/// bridged skin draws its ball. Images go to LAB_BRIDGE_OUT (TEST_RUNNER_LAB_BRIDGE_OUT) for review.
final class LabBridgeTests: XCTestCase {
    private func save(_ image: CGImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LAB_BRIDGE_OUT"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
    }
    private func opaquePixels(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 8 }.count
    }

    func testEveryBridgedEffectDrawsAnIcon() throws {
        let engine = try MetalEffectEngine()
        var failures = [String]()
        for style in BallStyle.bridged {
            let image = try EffectIconRenderer.image(shaderStyle: style.shaderID, height: 240, ball: nil, engine: engine)
            guard let image else { failures.append(style.rawValue + " (nil)"); continue }
            save(image, "effect-" + style.rawValue)
            if opaquePixels(image) < 50 { failures.append(style.rawValue + " (empty)") }
        }
        XCTAssertEqual(failures, [])
    }

    func testEveryBridgedSkinDrawsItsBall() {
        var failures = [String]()
        for skin in BallSkin.bridgedSkins {
            let pose = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
            guard let image = LabSkinBridge.shared.image(skin: skin, orientation: pose, size: 160) else { failures.append(skin.rawValue + " (nil)"); continue }
            save(image, "skin-" + skin.rawValue)
            if opaquePixels(image) < 4000 { failures.append(skin.rawValue + " (empty)") }
        }
        XCTAssertEqual(failures, [])
    }
}
