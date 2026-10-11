import AVFoundation
import XCTest
@testable import kicklab

@MainActor
final class VideoOnlyOrientationTests: XCTestCase {
    func testAlreadyUprightPortraitAndLandscapeStayUprightInSavedFile() async throws {
        for (width, height) in [(128, 72), (72, 128)] {
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixels)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let recorder = Recorder()
            try recorder.start(width: width, height: height, pixelsAreUpright: true)
            for frame in 0..<6 {
                var appended = false
                for _ in 0..<100 {
                    if try recorder.append(buffer, at: CMTime(value: Int64(frame), timescale: 60)) != nil {
                        appended = true; break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertTrue(appended)
            }
            let result: Result<URL, Error> = await withCheckedContinuation { continuation in
                recorder.stop { continuation.resume(returning: $0) }
            }
            let file = try result.get()
            defer { try? FileManager.default.removeItem(at: file) }
            let asset = AVURLAsset(url: file)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            XCTAssertEqual(size, CGSize(width: width, height: height))
            XCTAssertEqual(transform, .identity, "Landscape must not receive an extra portrait rotation")
        }
    }
}
