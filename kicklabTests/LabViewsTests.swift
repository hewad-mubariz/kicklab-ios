import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import UIKit
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

    /// The same preparation on a phone, from the app's Documents (lab-clip.mp4, lab-analysis.json, lab-touches.json
    /// copied with devicectl). Logs progress, seconds and memory footprint, so a stall or a memory climb shows.
    func testPrepareOnThePhone() async throws {
        let docs = URL.documentsDirectory
        let video = docs.appendingPathComponent("lab-clip.mp4")
        guard FileManager.default.fileExists(atPath: video.path) else { throw XCTSkip("lab-clip.mp4 not in Documents") }
        struct Row: Decodable { let time, x, y, width, height, score: Double; let personX, personY, personWidth, personHeight: Double? }
        struct File: Decodable { let track: [Row] }
        let rows = try JSONDecoder().decode(File.self, from: Data(contentsOf: docs.appendingPathComponent("lab-analysis.json"))).track
        let frames = rows.map { r in
            RecordedFrame(time: r.time, x: r.x, y: r.y, width: r.width, height: r.height, score: r.score, smoothedX: r.x, smoothedY: r.y,
                          vy: 0, motion: .unknown, detected: r.score > 0,
                          person: r.personX.map { PersonBox(x: $0, y: r.personY ?? 0, width: r.personWidth ?? 0, height: r.personHeight ?? 0) })
        }
        let touches = try JSONDecoder().decode([Double].self, from: Data(contentsOf: docs.appendingPathComponent("lab-touches.json")))
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        let started = Date()
        let log = LogBox()
        log.add(String(format: "start: %.0f MB", footprintMB()))
        let data = try await LabViewsPrep.prepare(video: video, frames: frames, touches: touches) { value in
            let step = Int(value * 20)
            guard log.claim(step) else { return }
            log.add(String(format: "%3d%%  %5.1f s  %5.0f MB", Int(value * 100), Date().timeIntervalSince(started), footprintMB()))
        }
        let lensCount = data.lensFrames.values.reduce(0) { $0 + $1.count }
        let lensMB = Double(data.lensFrames.values.flatMap { $0 }.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }) / 1_048_576
        log.add(String(format: "done: %.1f s, %.0f MB, feet %@, lens %d crops %.0f MB", Date().timeIntervalSince(started), footprintMB(),
                       data.sides, lensCount, lensMB))
        print("LAB-PREP-PHONE\n" + log.lines.joined(separator: "\n"))
        let attachment = XCTAttachment(string: log.lines.joined(separator: "\n"))
        attachment.name = "Lab views preparation on the phone"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(data.sides.count, touches.count)
        // Foot Rally and Left · Right drawn on the phone over real frames, attached for review.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let w = Int(data.size.width / 2), h = Int(data.size.height / 2)
        for view in [LabViewID.footRally, .leftRight] {
            for t in [5.45, 10.5, 15.4] {
                let (frame, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
                c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 0.5, y: -0.5)
                LabViewsDraw.draw(view, in: c, data: data, time: t)
                guard let image = c.makeImage() else { continue }
                let shot = XCTAttachment(image: UIImage(cgImage: image))
                shot.name = "\(view.rawValue) at \(t) s"; shot.lifetime = .keepAlways; add(shot)
            }
        }
    }

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<Int>()
        private(set) var lines = [String]()
        func claim(_ step: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return seen.insert(step).inserted }
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock(); print("LAB-PREP " + line) }
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
