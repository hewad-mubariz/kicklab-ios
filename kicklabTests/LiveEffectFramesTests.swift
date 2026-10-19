import CoreImage
import MetalKit
import XCTest
@testable import kicklab

final class LiveEffectFramesTests: XCTestCase {
    @MainActor
    func testLiveSurfaceRendersMatchedImageAndFallsBackOnStall() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let original = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let view = EffectVideoView(), feed = LiveEffectFrames()
        defer { view.stop(); window.isHidden = true; window.rootViewController = nil; original?.makeKey() }
        view.frame = CGRect(x: 0, y: 0, width: 72, height: 128)
        window.rootViewController!.view.addSubview(view)
        view.drawableSize = CGSize(width: 72, height: 128)
        view.configure(live: feed)
        XCTAssertTrue(view.isHidden)
        let image = try pixels()
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 72, height: 128)), to: image)
        feed.publish(pixels: image, time: 1, due: 100, ball: nil)
        XCTAssertTrue(view.consumeLiveFrame(now: 100.2)); XCTAssertFalse(view.isHidden)
        let drawable = try XCTUnwrap(view.currentDrawable)
        view.draw(view.bounds)
        let resources = try MetalEffectEngine.Resources.shared.get()
        let buffer = try XCTUnwrap(resources.device.makeBuffer(length: 72 * 128 * 4, options: .storageModeShared))
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 72, height: 128, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: 72 * 4, destinationBytesPerImage: 72 * 128 * 4)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[0], 240); XCTAssertLessThan(bytes[2], 5)
        XCTAssertFalse(view.consumeLiveFrame(now: 100.71)); XCTAssertTrue(view.isHidden)
        view.stop()
        feed.publish(pixels: image, time: 2, due: 101, ball: nil)
        XCTAssertNil(feed.frame(now: 101.2))
    }

    func testPreviewLeavesCounterInputOrderedAndUsesTakeRelativeTime() throws {
        let consumer = RFLiveConsumer(), image = try pixels()
        var seen: [Double] = []
        consumer.process = { output in seen.append(output.frame.time); return nil }
        consumer.preview.setEnabled(true)
        for i in 0..<10 {
            let t = Double(i) / 30
            let frame = PacedFrame(index: i, time: 100 + t, due: 1_000 + t,
                image: CIImage(cvPixelBuffer: image), pixels: image, recordingStart: 100)
            _ = try consumer.submit(RFTrackedFrame(frame: frame, found: FrameDetections(ball: nil, person: nil),
                                                   metrics: RFFrameMetrics(compute: "test")))
        }
        try consumer.drain()
        XCTAssertEqual(seen, (0..<10).map { 100 + Double($0) / 30 })
        XCTAssertEqual(try XCTUnwrap(consumer.preview.frame(now: 1_000.5)).time, 0.3, accuracy: 0.000001)
        XCTAssertEqual(consumer.summary["processed"], 10)
    }

    private func pixels() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 72, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value), kCVReturnSuccess)
        return try XCTUnwrap(value)
    }

    func testImageAndObservationHaveOneSourceClockAndBoundedHistory() throws {
        let feed = LiveEffectFrames(), image = try pixels()
        feed.setEnabled(true)
        for i in 0..<120 {
            let time = Double(i) / 30
            feed.publish(pixels: image, time: time, due: 100 + time,
                ball: Detection(score: 0.98, x: Double(i) / 240, y: 0.5, width: 0.1, height: 0.05625))
        }
        let frame = try XCTUnwrap(feed.frame(now: 104.2))
        XCTAssertTrue(frame.pixels === image)
        XCTAssertEqual(frame.time, 119.0 / 30)
        XCTAssertEqual(frame.sample?.time, frame.time)
        XCTAssertEqual(frame.sample?.center.x, 119.0 / 240)
        XCTAssertLessThanOrEqual(frame.trail.count, 32)
        XCTAssertTrue(frame.trail.allSatisfy { frame.time - $0.time >= 0 && frame.time - $0.time <= 0.85 })
        let effect = EffectFrame.tracked(size: CGSize(width: 390, height: 844),
            sourceSize: CGSize(width: 72, height: 128), style: .glowTrail, intensity: 0.38,
            sample: try XCTUnwrap(frame.sample), trail: frame.trail, time: frame.time)
        let crop = EffectVideoGeometry.aspectFillRect(source: CGSize(width: 72, height: 128),
                                                      destination: CGSize(width: 390, height: 844))
        XCTAssertEqual(Double(effect.center.x), crop.minX + 119.0 / 240 * crop.width, accuracy: 0.001)
    }

    func testMissAdvancesVideoWithoutHoldingOldBallAndStallReleasesFrame() throws {
        let feed = LiveEffectFrames(), first = try pixels(), second = try pixels()
        feed.setEnabled(true)
        feed.publish(pixels: first, time: 1, due: 10,
                     ball: Detection(score: 0.9, x: 0.5, y: 0.5, width: 0.1, height: 0.1))
        feed.publish(pixels: second, time: 1.03, due: 10.03, ball: nil)
        let missing = try XCTUnwrap(feed.frame(now: 10.3))
        XCTAssertTrue(missing.pixels === second); XCTAssertNil(missing.sample)
        XCTAssertNil(feed.frame(now: 10.74))
        // A new take can start from zero without inheriting history or timestamps.
        feed.reset()
        feed.publish(pixels: first, time: 0, due: 20, ball: nil)
        XCTAssertEqual(feed.frame(now: 20.2)?.time, 0)
        XCTAssertEqual(feed.frame(now: 20.2)?.trail.count, 0)
        feed.setEnabled(false)
        feed.publish(pixels: second, time: 0.03, due: 20.03, ball: nil)
        XCTAssertNil(feed.frame(now: 20.3))
    }
}
