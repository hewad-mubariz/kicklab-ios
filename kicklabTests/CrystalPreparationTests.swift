import Metal
import UIKit
import XCTest
@testable import kicklab

@MainActor
final class CrystalPreparationTests: XCTestCase {
    private final class Token: @unchecked Sendable {}
    private struct ExpectedFailure: Error {}

    func testSlowPreparationLeavesMainActorAvailableAndBuildsOnlyOnce() async throws {
        let started = expectation(description: "One background build")
        started.assertForOverFulfill = true
        let finished = expectation(description: "All interested previews notified")
        finished.expectedFulfillmentCount = 12
        let release = DispatchSemaphore(value: 0), token = Token()
        defer { release.signal() }
        let preparation = EffectResourcePreparation {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return token
        }
        for _ in 0..<12 {
            preparation.prepare { result in
                XCTAssertTrue((try? result.get()) === token)
                finished.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        // The main actor gets here while the builder remains deliberately blocked. Reading the
        // pending state must also return immediately, rather than joining that worker.
        XCTAssertNil(preparation.resultIfReady)
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(try preparation.resultIfReady?.get() === token)
        let export = try await Task.detached { try preparation.waitUntilReady() }.value
        XCTAssertTrue(export === token)
    }

    func testFailuresAreDeliveredAndCachedWithoutRepeatedCompilation() async throws {
        let built = expectation(description: "Only one failing build")
        built.assertForOverFulfill = true
        let reported = expectation(description: "Failure reported")
        let preparation = EffectResourcePreparation<Token> {
            built.fulfill()
            throw ExpectedFailure()
        }
        preparation.prepare { result in
            if case .failure(let error) = result { XCTAssertTrue(error is ExpectedFailure) }
            else { XCTFail("Expected preparation to fail") }
            reported.fulfill()
        }
        await fulfillment(of: [built, reported], timeout: 3)
        do {
            _ = try await Task.detached { try preparation.waitUntilReady() }.value
            XCTFail("Export must receive the preparation error")
        } catch { XCTAssertTrue(error is ExpectedFailure) }
        preparation.prepare()
        XCTAssertThrowsError(try preparation.resultIfReady?.get())
    }

    func testPendingPreviewDrawsVideoThenCrystalAndFullQualityIsUnchanged() async throws {
        let shared = try MetalEffectEngine.Resources.shared.get()
        let renderer = try await Task.detached { try shared.crystal.waitUntilReady() }.value
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let built = expectation(description: "Delayed resource published")
        let preparation = EffectResourcePreparation {
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return renderer
        }
        preparation.prepare { _ in built.fulfill() }
        let resources = try MetalEffectEngine.Resources(crystalPreparation: preparation)
        let preview = try MetalEffectEngine(resources: resources)
        preview.livePreview = true
        let source = try preview.texture(width: 128, height: 192, storage: .shared)
        let target = try preview.texture(width: 128, height: 192, storage: .shared)
        var pixels = [UInt8](repeating: 85, count: 128 * 192 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 128, 192), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 128 * 4)
        }
        let ice = CrystalFrame.make(time: 2, size: CGSize(width: 128, height: 192), strength: 1,
            track: CrystalTrack(sample: { _ in SIMD4(64, 100, 15, 1) }, touchTimes: [1.8]))
        var frame = EffectFrame(size: CGSize(width: 128, height: 192), center: SIMD2(64, 100),
                               radius: 15, time: 2, intensity: 0.7, style: BallStyle.crystal.shaderID)
        frame.crystal = ice
        try preview.render(frame, into: target, source: source)
        XCTAssertEqual(read(target), pixels, "Pending preparation must preserve the video")
        XCTAssertNil(preparation.resultIfReady)
        release.signal()
        await fulfillment(of: [built], timeout: 3)
        try preview.render(frame, into: target, source: source)
        XCTAssertNotEqual(read(target), pixels, "Crystal should appear once prepared")

        let export = try MetalEffectEngine(resources: resources)
        XCTAssertFalse(export.livePreview)
        XCTAssertTrue(try export.resources.crystal.waitUntilReady() === renderer)
        try export.render(frame, into: target, source: source)
        let exported = read(target)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        try renderer.encode(frame: ice, source: source, target: target, command: command)
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        XCTAssertNil(command.error)
        XCTAssertEqual(read(target), exported, "Export must match the original full-quality renderer exactly")
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    func testPausedPreviewRefreshesWhenPreparationFinishes() async throws {
        let shared = try MetalEffectEngine.Resources.shared.get()
        let renderer = try await Task.detached { try shared.crystal.waitUntilReady() }.value
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let preparation = EffectResourcePreparation {
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return renderer
        }
        let resources = try MetalEffectEngine.Resources(crystalPreparation: preparation)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let view = EffectVideoView(resources: resources)
        defer { view.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        view.frame = CGRect(x: 0, y: 0, width: 128, height: 192)
        window.rootViewController!.view.addSubview(view)
        // An explicit RGBA fixture: UIGraphicsImageRenderer can optimize a plain grey image into
        // a single-channel format that MTKTextureLoader does not accept on the Simulator.
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 192, bitsPerComponent: 8,
            bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.35, green: 0.4, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 192))
        let image = try XCTUnwrap(context.makeImage())
        let frames = (0..<91).map { i in
            RecordedFrame(time: Double(i) / 30, x: 0.5, y: 0.6, width: 0.15, height: 0.1,
                score: 1, smoothedX: 0.5, smoothedY: 0.6, vy: 0, motion: .unknown, detected: true, person: nil)
        }
        var failures: [String] = []
        view.onFailure = { failures.append($0) }
        view.configure(image: image, edit: SessionEditState(style: .crystal), track: BallEffectTrack(frames: frames), time: 2)
        view.draw(view.bounds)
        try await Task.sleep(for: .milliseconds(100))
        let before = view.presentedFrameCount
        XCTAssertGreaterThan(before, 0)
        XCTAssertNil(preparation.resultIfReady)
        release.signal()
        for _ in 0..<100 {
            if view.presentedFrameCount > before { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(view.presentedFrameCount, before, "A paused preview must redraw without a tap or seek")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
}
