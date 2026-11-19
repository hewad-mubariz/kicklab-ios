import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import kicklab

/// Runs the analytics lab views' whole in-app path on the owner's 19 s clip (read from the Mac's disk by the
/// Simulator): body pose, foot rule, lens crops, then every view drawn over the frame. Images go to
/// LAB_BRIDGE_OUT (TEST_RUNNER_LAB_BRIDGE_OUT).
final class LabViewsTests: XCTestCase {
    func testVisionPoseOnOneFrame() async throws {
        let video = URL(fileURLWithPath: "/Users/hewadmubariz/Desktop/projects/kicklab/artifacts/launch-demo-20261011/v2/source-1080p120.mp4")
        guard FileManager.default.fileExists(atPath: video.path) else { throw XCTSkip("clip missing") }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        let (image, _) = try await generator.image(at: CMTime(seconds: 5.4, preferredTimescale: 600))
        let request = VNDetectHumanBodyPoseRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { print("VISION ERROR", error) }
        print("VISION results", request.results?.count ?? -1, (try? request.results?.first?.recognizedPoints(.all).count) ?? -1)
    }

    func testEveryLabViewOnTheOwnersClip() async throws {
        let root = "/Users/hewadmubariz/Desktop/projects"
        let analysis = URL(fileURLWithPath: root + "/kicklab/artifacts/launch-demo-20261011/analysis-native.json")
        let video = URL(fileURLWithPath: root + "/kicklab/artifacts/launch-demo-20261011/v2/source-1080p120.mp4")
        let touchesURL = URL(fileURLWithPath: root + "/kicklab-effects-lab/references/liquid-spectrum/touches.json")
        guard FileManager.default.fileExists(atPath: analysis.path) else { throw XCTSkip("owner's clip not on this machine") }
        struct Row: Decodable { let time, x, y, width, height, score: Double; let personX, personY, personWidth, personHeight: Double? }
        struct File: Decodable { let track: [Row] }
        let rows = try JSONDecoder().decode(File.self, from: Data(contentsOf: analysis)).track
        let frames = rows.map { r in
            RecordedFrame(time: r.time, x: r.x, y: r.y, width: r.width, height: r.height, score: r.score, smoothedX: r.x, smoothedY: r.y,
                          vy: 0, motion: .unknown, detected: r.score > 0,
                          person: r.personX.map { PersonBox(x: $0, y: r.personY ?? 0, width: r.personWidth ?? 0, height: r.personHeight ?? 0) })
        }
        let touches = try JSONDecoder().decode([Double].self, from: Data(contentsOf: touchesURL))
        let started = Date()
        let data = try await LabViewsPrep.prepare(video: video, frames: frames, touches: touches) { _ in }
        print("lab views prepared in \(Date().timeIntervalSince(started)) s; feet \(data.sides); lens touches \(data.lensFrames.count)")
        XCTAssertEqual(data.sides.count, touches.count)
        XCTAssertGreaterThan(data.sides.filter { $0 != "U" }.count, touches.count / 2)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let out = ProcessInfo.processInfo.environment["LAB_BRIDGE_OUT"].map { URL(fileURLWithPath: $0) }
        let w = Int(data.size.width / 2), h = Int(data.size.height / 2)
        for t in [5.45, 10.5] {
            let (frame, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            for view in LabViewID.allCases {
                let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
                c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 0.5, y: -0.5)
                LabViewsDraw.draw(view, in: c, data: data, time: t)
                guard let out, let image = c.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("view-\(view.rawValue)-\(t).png") as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
            }
        }
    }
}
