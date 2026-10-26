import CoreImage
import CoreVideo
import XCTest
@testable import kicklab

final class ContactBufferReuseTests: XCTestCase {
    private let ball = Detection(score: 0.9, x: 0.5, y: 0.5, width: 0.1, height: 0.1)

    func testContactRetryUsesTheOriginalExposureClockAcrossFractionalMilliseconds() throws {
        let store = ContactObservationStore()
        let pixels = try source(width: 72, height: 128, seed: 1)
        // Original capture times of the two missed kicks at 20.27s and 22.31s.
        for (index, time) in [36921.137531541, 36923.171685833].enumerated() {
            let frame = PacedFrame(index: index, time: time, due: time,
                image: CIImage(cvPixelBuffer: pixels), pixels: pixels)
            store.store(pixels, frameIndex: index, timestampMs: frame.timestampMs, ball: nil)
            XCTAssertFalse(store.insertRecheckedContact(pixels, frameIndex: index,
                timestampMs: Int((time * 1000).rounded()), ball: ball), "A different exposure clock must stay invalid")
            XCTAssertTrue(store.insertRecheckedContact(pixels, frameIndex: index,
                timestampMs: frame.timestampMs, ball: ball))
            XCTAssertEqual(store.frames.last?.timestampMs, Int(time * 1000))
            XCTAssertFalse(store.insertRecheckedContact(pixels, frameIndex: index,
                timestampMs: frame.timestampMs, ball: ball), "A retry cannot duplicate the observation")
        }
    }

    private func source(width: Int, height: Int, seed: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            bytes[y * stride + x * 4] = UInt8((x + seed * 11) % 256)
            bytes[y * stride + x * 4 + 1] = UInt8((y + seed * 23) % 256)
            bytes[y * stride + x * 4 + 2] = UInt8((x + y + seed * 37) % 256)
            bytes[y * stride + x * 4 + 3] = 255
        } }
        return buffer
    }

    /// Compare active pixels, excluding allocator-dependent row padding.
    private func bytes(_ buffer: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer), row = CVPixelBufferGetWidth(buffer) * 4
        var result = Data()
        for y in 0..<CVPixelBufferGetHeight(buffer) { result.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: row) }
        return result
    }

    func testRecycledImagesDoNotOverwriteRetainedOrExternallyHeldContactFrames() throws {
        let store = ContactObservationStore()
        var expected: [Int: Data] = [:]
        var pinned: CVPixelBuffer?
        for i in 0..<80 {
            try autoreleasepool {
                store.store(try source(width: 128, height: 72, seed: i), frameIndex: i,
                    timestampMs: i * 33, ball: ball)
                let current = try XCTUnwrap(store.frames.first { $0.index == i })
                expected[i] = try bytes(current.pixels)
                if i == 0 { pinned = current.pixels }
                for frame in store.frames { XCTAssertEqual(try bytes(frame.pixels), expected[frame.index]) }
            }
        }
        XCTAssertNil(store.frames.first { $0.index == 0 })
        XCTAssertEqual(try bytes(XCTUnwrap(pinned)), expected[0])
        XCTAssertLessThan(store.frames.count, 30)
    }

    func testPooledPixelsMatchIndependentRenderedImagesAcrossOrientationAndSizeChanges() throws {
        let store = ContactObservationStore()
        let context = CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly])
        for (i, shape) in [(1280, 720, true), (720, 1280, true), (1280, 720, false), (128, 72, true)].enumerated() {
            let (width, height, rotate) = shape
            let pixels = try source(width: width, height: height, seed: i)
            store.store(pixels, frameIndex: i, timestampMs: i * 33, ball: ball, orientLandscapeAsPortrait: rotate)
            let actual = try XCTUnwrap(store.frames.last?.pixels)
            var image = CIImage(cvPixelBuffer: pixels)
            if rotate && width > height { image = image.oriented(.right) }
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let scale = min(1, 512 / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let reference = try source(width: Int(image.extent.width), height: Int(image.extent.height), seed: 0)
            context.render(image, to: reference)
            XCTAssertEqual(CVPixelBufferGetWidth(actual), CVPixelBufferGetWidth(reference))
            XCTAssertEqual(CVPixelBufferGetHeight(actual), CVPixelBufferGetHeight(reference))
            XCTAssertEqual(try bytes(actual), try bytes(reference))
        }
    }

    func testResetCanReleaseThePoolWithoutInvalidatingAnOutstandingFrame() throws {
        let store = ContactObservationStore()
        store.store(try source(width: 128, height: 72, seed: 1), frameIndex: 0, timestampMs: 0, ball: ball)
        let held = try XCTUnwrap(store.frames.first?.pixels), expected = try bytes(held)
        store.reset()
        store.store(try source(width: 128, height: 72, seed: 2), frameIndex: 0, timestampMs: 0, ball: ball)
        XCTAssertEqual(try bytes(held), expected)
        XCTAssertNotEqual(try bytes(XCTUnwrap(store.frames.first?.pixels)), expected)
    }
}
