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

    /// The Ball page's own path (BallSkinSphereRenderer, rest pose and spin frames) for every lab skin,
    /// timed, so a phone run shows whether picker balls can come back empty and how long the first draw takes.
    func testBallPickerPathDrawsEveryLabSkin() {
        XCTAssertNotNil(LabSkinRenderer.shared, "Lab skin renderer failed to start")
        let pose = simd_quatf(angle: 1.89, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: 0.59, axis: SIMD3<Float>(1, 0, 0))
        var failures = [String](), report = [String]()
        for skin in BallSkin.pickerOrder where skin.isLabSkin {
            let start = Date()
            let rest = BallSkinSphereRenderer.image(skin: skin, time: 0, orientation: pose)
            let first = Date().timeIntervalSince(start)
            let spinStart = Date()
            let spin = BallSkinSphereRenderer.previewImage(skin: skin, time: 0, orientation: simd_normalize(simd_quatf(angle: 0.7, axis: SIMD3<Float>(-1, 0, 0)) * pose))
            let frame = Date().timeIntervalSince(spinStart)
            report.append(String(format: "%@ first %.0f ms, spin frame %.0f ms", skin.rawValue, first * 1000, frame * 1000))
            if let rest { save(rest, "picker-" + skin.rawValue); if opaquePixels(rest) < 2000 { failures.append(skin.rawValue + " rest (empty)") } }
            else { failures.append(skin.rawValue + " rest (nil)") }
            if spin == nil { failures.append(skin.rawValue + " spin (nil)") }
        }
        print("LAB-PICKER-TIMINGS\n" + report.joined(separator: "\n"))
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "Lab skin picker timings"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(failures, [])
    }

    /// The Ball page's resting balls, saved as ball-thumb-<skin>.png in LAB_BRIDGE_OUT. The app ships them so
    /// the picker shows every ball at once, even while a session's preparation keeps the GPU busy.
    func testBallPickerThumbnails() throws {
        guard ProcessInfo.processInfo.environment["LAB_BRIDGE_OUT"] != nil else { throw XCTSkip("LAB_BRIDGE_OUT not set") }
        // BallPickSlot's resting pose.
        let pose = simd_quatf(angle: 1.89, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: 0.59, axis: SIMD3<Float>(1, 0, 0))
        var missing = [String]()
        for skin in BallSkin.pickerOrder where skin != .original {
            guard let image = BallSkinSphereRenderer.image(skin: skin, time: 0, orientation: pose), opaquePixels(image) > 2000 else {
                missing.append(skin.rawValue); continue
            }
            save(image, "ball-thumb-" + skin.rawValue)
        }
        XCTAssertEqual(missing, [])
    }

    /// Every picker ball ships its resting picture, so no ball waits for the GPU to appear.
    func testEveryBallShipsItsPicture() {
        let missing = BallSkin.pickerOrder.filter { $0 != .original && ShippedBallImage.image(for: $0) == nil }.map(\.rawValue)
        XCTAssertEqual(missing, [])
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
