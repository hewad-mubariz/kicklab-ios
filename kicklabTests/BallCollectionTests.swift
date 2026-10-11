import AVFoundation
import simd
import UIKit
import XCTest
@testable import kicklab

final class BallCollectionTests: XCTestCase {
    private let skins = BallSkin.allCases.filter { $0 != .original }

    func testAllMaterialsRotateContinuouslyAndKeepDeterministicPremultipliedEdges() throws {
        for skin in skins {
            func render(_ angle: Float, time: Double = 0) throws -> [UInt8] {
                let pose = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
                let image = try XCTUnwrap(BallSkinSphereRenderer.image(skin: skin, time: time, orientation: pose))
                XCTAssertEqual(image.width, 256, "Every replacement uses the detailed material renderer")
                return [UInt8](image.dataProvider!.data! as Data)
            }
            let front = try render(0), half = try render(.pi), full = try render(2 * .pi)
            XCTAssertNotEqual(front, half, "\(skin) surface must rotate")
            XCTAssertEqual(front, try render(0, time: 77), "A saved source pose must survive seeking")
            var turnError = 0.0
            for index in stride(from: 0, to: front.count, by: 4) {
                XCTAssertEqual(front[index + 3], half[index + 3])
                for c in 0..<3 {
                    XCTAssertLessThanOrEqual(front[index + c], front[index + 3])
                    turnError += abs(Double(front[index + c]) - Double(full[index + c]))
                }
            }
            XCTAssertLessThan(turnError / Double(front.count / 4 * 3), 0.02, "No seam after a complete turn")
            XCTAssertNotNil(BallSkinSphereRenderer.previewImage(skin: skin, time: 1.4))
        }
    }

    func testConcurrentMaterialEvictionKeepsPreviewAndExportIdentical() async {
        let skins = self.skins
        let results = await withTaskGroup(of: [String: Data].self) { group in
            for worker in 0..<4 {
                group.addTask {
                    var result = [String: Data]()
                    // Different traversal order forces eviction during simultaneous rendering.
                    for i in skins.indices {
                        let skin = skins[(i + worker * 3) % skins.count]
                        let pose = simd_quatf(angle: 0.62, axis: SIMD3<Float>(0, 1, 0))
                        if let image = BallSkinSphereRenderer.image(skin: skin, time: Double(worker), orientation: pose),
                           let bytes = image.dataProvider?.data {
                            result[skin.rawValue] = bytes as Data
                        }
                    }
                    return result
                }
            }
            var values = [[String: Data]]()
            for await result in group { values.append(result) }
            return values
        }
        for result in results {
            XCTAssertEqual(result.count, skins.count)
            XCTAssertEqual(result, results.first)
        }
        XCTAssertLessThanOrEqual(BallSkinSphereRenderer.decodedArtworkBytes, 14 * 1024 * 1024)
    }

    /// Encode and decode every material through the actual video exporter, not just its thumbnail.
    func testEveryMaterialSurvivesVideoExportWithoutTouchingTheBackground() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let movie = try PreviewMovie(url: source, size: CGSize(width: 320, height: 480), frameRate: 30)
        let buffer = try movie.buffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 480,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        context.setFillColor(CGColor(gray: 0.93, alpha: 1)); context.fillEllipse(in: CGRect(x: 112, y: 192, width: 96, height: 96))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<3 { try await movie.append(buffer, time: CMTime(value: Int64(index), timescale: 30)) }
        try await movie.finish(duration: CMTime(value: 3, timescale: 30))
        let alpha = (0..<10000).map { i -> UInt8 in
            hypot(Double(i % 100) + 0.5 - 50, Double(i / 100) + 0.5 - 50) < 48 ? 255 : 0
        }
        let mask = BallMask(rect: CGRect(x: 110.0/320, y: 190.0/480, width: 100.0/320, height: 100.0/480),
                            width: 100, height: 100, alpha: alpha)
        let frames = (0..<3).map { index in
            RecordedFrame(time: Double(index)/30, x: 0.5, y: 0.5, width: 96.0/320, height: 96.0/480,
                score: 0.99, smoothedX: 0.5, smoothedY: 0.5, vy: 0, motion: .unknown, detected: true,
                person: nil, ballMask: mask, usesBallMasks: true)
        }
        var appearances: [SIMD3<Double>] = []
        var exportedImages = Set<Data>()
        for skin in skins {
            let exported = try await BallStyleBurnIn.render(source: source, track: frames, style: .none,
                skin: skin, intensity: 0, shortEdge: 320, preserveFrameTimes: true)
            defer { try? FileManager.default.removeItem(at: exported) }
            let asset = AVURLAsset(url: exported), track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            defer { reader.cancelReading() }
            let sample = try XCTUnwrap(output.copyNextSampleBuffer())
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            var color = SIMD3<Double>.zero, count = 0.0, leaked = 0
            for y in 0..<480 { for x in 0..<320 {
                let offset = y * stride + x * 4, radius = hypot(Double(x) + 0.5 - 160, Double(y) + 0.5 - 240)
                if radius < 40 {
                    color += SIMD3(Double(bytes[offset + 2]), Double(bytes[offset + 1]), Double(bytes[offset]))
                    count += 1
                }
                if radius > 65 && max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 45 { leaked += 1 }
            } }
            XCTAssertEqual(leaked, 0, "\(skin) cannot paint outside the ball")
            color /= count
            if [.metal, .lava, .pearl, .volt].contains(skin) { appearances.append(color) }
            switch skin {
            case .metal: XCTAssertLessThan(abs(color.x - color.z), 8)
            case .lava: XCTAssertGreaterThan(color.x, color.z + 8)
            case .pearl: XCTAssertGreaterThan(min(color.x, color.y, color.z), 135)
            case .volt: XCTAssertGreaterThan(color.y, color.z + 90)
            default: break
            }
            let generator = AVAssetImageGenerator(asset: asset)
            let (image, _) = try await generator.image(at: .zero)
            exportedImages.insert(try XCTUnwrap(image.dataProvider?.data) as Data)
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "\(skin.title) — encoded export"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(exportedImages.count, skins.count, "Every exported ball keeps its own artwork")
        for i in appearances.indices { for j in appearances.indices where j > i {
            XCTAssertGreaterThan(simd_distance(appearances[i], appearances[j]), 30, "Each saved look must remain distinct")
        } }
    }
}
