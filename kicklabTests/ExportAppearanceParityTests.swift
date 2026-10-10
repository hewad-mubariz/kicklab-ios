import AVFoundation
import CoreImage
import CoreGraphics
import XCTest
@testable import kicklab

final class ExportAppearanceParityTests: XCTestCase {
    /// A prepared source is decoded at its original size even when the final
    /// export is smaller. Its mask/material must stay on the same physical ball.
    func testSourceMeasuredMaterialStaysRegisteredWhenPreparedExportIsResized() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let movie = try PreviewMovie(url: source, size: CGSize(width: 320, height: 640), frameRate: 60)
        let buffer = try movie.buffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 640,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 640))
        ctx.translateBy(x: 0, y: 640); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 194, y: 270, width: 60, height: 60))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<3 { try await movie.append(buffer, time: CMTime(value: Int64(index), timescale: 60)) }
        try await movie.finish(duration: CMTime(value: 3, timescale: 60))
        let alpha = (0..<4096).map { i -> UInt8 in
            let x = Double(i % 64) + 0.5 - 32, y = Double(i / 64) + 0.5 - 32
            return x*x+y*y < 30*30 ? 255 : 0
        }
        let mask = BallMask(rect: CGRect(x: 192.0/320, y: 268.0/640, width: 64.0/320, height: 64.0/640), width: 64, height: 64, alpha: alpha)
        let frames = (0..<3).map { i in RecordedFrame(time: Double(i)/60, x: 224.0/320, y: 300.0/640,
            width: 60.0/320, height: 60.0/640, score: 0.99, smoothedX: 224.0/320, smoothedY: 300.0/640,
            vy: 0, motion: .unknown, detected: true, person: nil, ballMask: mask, usesBallMasks: true) }
        for shortEdge in [320, 160] {
            let exported = try await BallStyleBurnIn.render(source: source, track: frames, style: .none,
                skin: .gold, intensity: 0, shortEdge: shortEdge, preserveFrameTimes: true)
            defer { try? FileManager.default.removeItem(at: exported) }
            let asset = AVURLAsset(url: exported), track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            defer { reader.cancelReading() }
            let sample = try XCTUnwrap(output.copyNextSampleBuffer()), pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), shortEdge)
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
            let scale = Double(shortEdge)/320
            var inside = 0, gold = 0, background = 0, leaked = 0
            var coloredX = 0.0, coloredY = 0.0, coloredCount = 0.0
            for y in 0..<(shortEdge*2) { for x in 0..<shortEdge {
                let dx = (Double(x)+0.5)/scale-224, dy = (Double(y)+0.5)/scale-300
                let p = bytes + y*stride+x*4, colored = Int(p[2])-Int(p[0]) > 12
                if dx*dx+dy*dy < 22*22 { inside += 1; if colored { gold += 1 } }
                if colored { coloredX += Double(x)+0.5; coloredY += Double(y)+0.5; coloredCount += 1 }
                if dx*dx+dy*dy > 45*45 { background += 1; if colored { leaked += 1 } }
            } }
            // Gold artwork includes neutral panels; use its colored region to
            // measure registration, not to infer alpha coverage from its color.
            XCTAssertGreaterThan(Double(gold)/Double(inside), 0.50, "The requested material must be visible on the ball")
            XCTAssertEqual(coloredX/max(1,coloredCount)/scale, 224, accuracy: 7)
            XCTAssertEqual(coloredY/max(1,coloredCount)/scale, 300, accuracy: 7)
            XCTAssertLessThan(Double(leaked)/Double(background), 0.001, "Material cannot move into the background")
        }
    }
}
