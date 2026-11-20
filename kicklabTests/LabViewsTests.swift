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

    /// The counter's own feet: the real import analysis on lab-clip.mp4, with no extra pose pass. Compares each
    /// counted touch's foot with the full 60 fps pass (29 L, 4 R on the lab's touch times).
    @MainActor
    func testCounterFeetOnThePhone() async throws {
        let docs = URL.documentsDirectory
        let video = docs.appendingPathComponent("lab-clip.mp4")
        guard FileManager.default.fileExists(atPath: video.path) else { throw XCTSkip("lab-clip.mp4 not in Documents") }
        let labTimes = try JSONDecoder().decode([Double].self, from: Data(contentsOf: docs.appendingPathComponent("lab-touches.json"))).sorted()
        let labSides = Array("RLLLLLLLRLRLLLLLLLLLLLLLLLLLLLLLR")
        let started = Date()
        let analyser = VideoAnalyzer()
        analyser.analyse(url: video)
        await analyser.waitUntilFinished()
        XCTAssertEqual(analyser.status, "done")
        let touches = analyser.recordedTouches
        var lines = [String(format: "analysis %.1f s, %d touches, feet %@", Date().timeIntervalSince(started), touches.count,
                            TouchFoot.letters(touches) ?? "none")]
        var agree = 0, differ = 0, unknown = 0, unmatched = 0
        for touch in touches {
            guard let k = labTimes.indices.min(by: { abs(labTimes[$0] - touch.time) < abs(labTimes[$1] - touch.time) }),
                  abs(labTimes[k] - touch.time) <= 0.06 else { unmatched += 1; continue }
            guard let foot = touch.foot else { unknown += 1; continue }
            if foot.rawValue == String(labSides[k]) { agree += 1 } else {
                differ += 1
                lines.append(String(format: "differs at %.2f s: counter %@, pass %@", touch.time, foot.rawValue, String(labSides[k])))
            }
        }
        lines.append("agree \(agree), differ \(differ), unknown \(unknown), not on the lab's touches \(unmatched)")

        // Feet-only views straight from those saved feet: no video pass.
        let quickStart = Date()
        let quick = try await LabViewsPrep.fromSavedFeet(video: video, frames: analyser.recordedTrack,
                                                         touches: touches.map(\.time), feet: touches.map(\.foot))
        lines.append(String(format: "feet-only views ready in %.2f s, sides %@, body %@", Date().timeIntervalSince(quickStart),
                            quick?.sides ?? "none", quick?.hasBody == true ? "yes" : "no"))
        XCTAssertNotNil(quick)
        if let quick {
            XCTAssertTrue(quick.covers(.footRally)); XCTAssertFalse(quick.covers(.peakZone))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let w = Int(quick.size.width / 2), h = Int(quick.size.height / 2)
            for t in [10.5, 15.4] {
                let (frame, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
                c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 0.5, y: -0.5)
                LabViewsDraw.draw(.footRally, in: c, data: quick, time: t)
                guard let image = c.makeImage() else { continue }
                let shot = XCTAttachment(image: UIImage(cgImage: image))
                shot.name = "foot-rally from saved feet at \(t) s"; shot.lifetime = .keepAlways; add(shot)
            }
        }
        print("COUNTER-FEET\n" + lines.joined(separator: "\n"))
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "Counter feet on the phone"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(differ, 0)
    }

    /// The Analytics grid's preview for each lab view, drawn on the phone (Vision body pose doesn't run in the
    /// Simulator) over the owner's clip at a moment where the view has something on screen. Strip views are
    /// cropped to their card, scene views to a band around the ball. Attached as analytics-preview-<id>.
    func testLabViewPreviewsOnThePhone() async throws {
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
        let data = try await LabViewsPrep.prepare(video: video, frames: frames, touches: touches) { _ in }
        let moments: [LabViewID: Double] = [
            .nextTouch: 9.86, .touchSignature: 15.7, .legSwing: 13.95, .ballFlight: 9.75, .recoveryChain: 10.95,
            .controlWindow: 11.0, .controlTopography: 15.2, .ghostBall: 9.75, .zoneGame: 9.95, .heightLadder: 9.95,
            .beatGame: 7.68, .touchLens: 3.52, .peakZone: 13.95, .touchZone: 14.1, .reach: 11.3, .footwork: 17.9,
            .controlSurf: 10.6, .beatGates: 15.4, .arcMatch: 15.4, .footRally: 15.4, .leftRight: 15.4]
        let strips: Set<LabViewID> = [.footRally, .leftRight, .beatGates, .arcMatch, .controlSurf, .peakZone, .touchZone, .reach, .footwork]
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let w = Int(data.size.width / 2), h = Int(data.size.height / 2)
        for view in LabViewID.allCases {
            let t = moments[view] ?? 15.4
            let (frame, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
            c.saveGState()
            c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 0.5, y: -0.5)
            LabViewsDraw.draw(view, in: c, data: data, time: t)
            c.restoreGState()
            guard let full = c.makeImage() else { continue }
            // Crop rects are in the half-size image, top-left origin.
            var crop: CGRect
            if strips.contains(view) {
                let strip = LabViewsDraw.strip(data.size)
                crop = CGRect(x: strip.minX / 2, y: strip.minY / 2, width: strip.width / 2, height: strip.height / 2).insetBy(dx: -6, dy: -6)
            } else {
                let height = CGFloat(w) / 2.3
                let ballY = data.ball.ball(at: t).map { CGFloat($0.p.y) / 2 } ?? CGFloat(h) * 0.45
                crop = CGRect(x: 0, y: min(max(0, ballY - height * 0.45), CGFloat(h) - height), width: CGFloat(w), height: height)
            }
            crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard let cut = full.cropping(to: crop) else { continue }
            let shot = XCTAttachment(image: UIImage(cgImage: cut))
            shot.name = "analytics-preview-" + view.rawValue; shot.lifetime = .keepAlways; add(shot)
        }
    }

    /// The Analytics grid's previews as diagrams, like the graph-style tiles: each view drawn on the tile's dark
    /// colour, with a grey silhouette and a plain ball in place of the footage. Runs on the Mac (Simulator) from
    /// the lab's saved body pose of the owner's clip, so no phone is needed. Saved to LAB_BRIDGE_OUT.
    func testLabViewDiagramPreviews() async throws {
        guard let out = ProcessInfo.processInfo.environment["LAB_BRIDGE_OUT"] else { throw XCTSkip("LAB_BRIDGE_OUT not set") }
        let root = "/Users/hewadmubariz/Desktop/projects"
        let video = URL(fileURLWithPath: root + "/kicklab/artifacts/launch-demo-20261011/v2/source-1080p120.mp4")
        let analysis = URL(fileURLWithPath: root + "/kicklab/artifacts/launch-demo-20261011/analysis-native.json")
        let touchesURL = URL(fileURLWithPath: root + "/kicklab-effects-lab/references/liquid-spectrum/touches.json")
        let poseURL = URL(fileURLWithPath: root + "/kicklab-effects-lab/references/body/pose-60fps.json")
        guard FileManager.default.fileExists(atPath: poseURL.path) else { throw XCTSkip("lab pose file not on this machine") }
        struct Row: Decodable { let time, x, y, width, height, score: Double; let personX, personY, personWidth, personHeight: Double? }
        struct File: Decodable { let track: [Row] }
        let frames = try JSONDecoder().decode(File.self, from: Data(contentsOf: analysis)).track.map { r in
            RecordedFrame(time: r.time, x: r.x, y: r.y, width: r.width, height: r.height, score: r.score, smoothedX: r.x, smoothedY: r.y,
                          vy: 0, motion: .unknown, detected: r.score > 0,
                          person: r.personX.map { PersonBox(x: $0, y: r.personY ?? 0, width: r.personWidth ?? 0, height: r.personHeight ?? 0) })
        }
        let touches = try JSONDecoder().decode([Double].self, from: Data(contentsOf: touchesURL)).sorted()
        // The phone's verified feet for these touches; the Simulator can't run Vision, so the pass only cuts the lens crops.
        let feet = Array("RLLLLLLLRLRLLLLLLLLLLLLLLLLLLLLLR").map { TouchFoot(rawValue: String($0)) }
        let base = try await LabViewsPrep.prepare(video: video, frames: frames, touches: touches, feet: feet) { _ in }
        let poses = try JSONDecoder().decode(BodyZones.PoseFile.self, from: Data(contentsOf: poseURL))
        let data = LabViewsData(video: base.video, size: base.size, ball: base.ball, motion: base.motion, feet: base.feet,
                                body: BodyZones.Body(poses), lensFrames: base.lensFrames, sides: base.sides)

        let moments: [LabViewID: Double] = [
            .nextTouch: 9.86, .touchSignature: 15.7, .legSwing: 13.95, .ballFlight: 9.75, .recoveryChain: 10.95,
            .controlWindow: 11.0, .controlTopography: 15.2, .ghostBall: 9.75, .zoneGame: 9.95, .heightLadder: 9.95,
            .beatGame: 7.68, .touchLens: 3.52, .peakZone: 13.95, .touchZone: 14.1, .reach: 11.3, .footwork: 17.9,
            .controlSurf: 10.6, .beatGates: 15.4, .arcMatch: 15.4, .footRally: 15.4, .leftRight: 15.4]
        let tile = CGColor(red: 0.05, green: 0.075, blue: 0.077, alpha: 1)
        let w = Int(data.size.width / 2), h = Int(data.size.height / 2)
        for view in LabViewID.allCases {
            let t = moments[view] ?? 15.4
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(tile); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.saveGState()
            c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 0.5, y: -0.5)
            if view.needsBody || [.footRally, .beatGates, .arcMatch, .controlSurf].contains(view) {
                if let pose = poses.frames.min(by: { abs($0.time - t) < abs($1.time - t) }) { Self.silhouette(c, pose.joints) }
                if let b = data.ball.ball(at: t) { Self.ball(c, center: CGPoint(x: CGFloat(b.p.x), y: CGFloat(b.p.y)), radius: CGFloat(b.r)) }
            }
            LabViewsDraw.draw(view, in: c, data: data, time: t)
            c.restoreGState()
            guard let full = c.makeImage() else { continue }
            var crop: CGRect
            let strips: Set<LabViewID> = [.footRally, .leftRight, .beatGates, .arcMatch, .controlSurf, .peakZone, .touchZone, .reach, .footwork]
            if strips.contains(view) {
                let strip = LabViewsDraw.strip(data.size)
                crop = CGRect(x: strip.minX / 2, y: strip.minY / 2, width: strip.width / 2, height: strip.height / 2).insetBy(dx: -6, dy: -6)
            } else {
                let height = CGFloat(w) / 2.3
                let ballY = data.ball.ball(at: t).map { CGFloat($0.p.y) / 2 } ?? CGFloat(h) * 0.45
                crop = CGRect(x: 0, y: min(max(0, ballY - height * 0.45), CGFloat(h) - height), width: CGFloat(w), height: height)
            }
            crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard let cut = full.cropping(to: crop),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out).appendingPathComponent("analytics-preview-\(view.rawValue).png") as CFURL,
                                                             UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cut, nil); CGImageDestinationFinalize(dest)
        }
    }

    /// A soft grey figure from the pose: torso, head, arms and legs as rounded strokes.
    private static func silhouette(_ c: CGContext, _ joints: [String: [Double]]) {
        func p(_ name: String) -> CGPoint? { joints[name].map { CGPoint(x: $0[0], y: $0[1]) } }
        c.saveGState(); defer { c.restoreGState() }
        c.setLineCap(.round); c.setLineJoin(.round)
        let body = CGColor(gray: 1, alpha: 0.13), edge = CGColor(gray: 1, alpha: 0.22)
        func limb(_ names: [String], width: CGFloat) {
            let points = names.compactMap(p)
            guard points.count == names.count, points.count > 1 else { return }
            c.beginPath(); c.addLines(between: points)
            c.setStrokeColor(edge); c.setLineWidth(width + 3); c.strokePath()
            c.beginPath(); c.addLines(between: points)
            c.setStrokeColor(body); c.setLineWidth(width); c.strokePath()
        }
        if let ls = p("leftShoulder"), let rs = p("rightShoulder"), let lh = p("leftHip"), let rh = p("rightHip") {
            c.beginPath(); c.addLines(between: [ls, rs, rh, lh]); c.closePath()
            c.setFillColor(body); c.setStrokeColor(edge); c.setLineWidth(3); c.drawPath(using: .fillStroke)
        }
        limb(["leftShoulder", "leftWrist"], width: 30); limb(["rightShoulder", "rightWrist"], width: 30)
        limb(["leftHip", "leftKnee", "leftAnkle"], width: 44); limb(["rightHip", "rightKnee", "rightAnkle"], width: 44)
        limb(["neck", "nose"], width: 26)
        if let nose = p("nose") {
            let head = CGRect(x: nose.x - 50, y: nose.y - 62, width: 100, height: 110)
            c.setFillColor(body); c.setStrokeColor(edge); c.setLineWidth(3)
            c.addEllipse(in: head); c.drawPath(using: .fillStroke)
        }
    }

    /// A plain lit ball: white to grey with a soft rim.
    private static func ball(_ c: CGContext, center: CGPoint, radius: CGFloat) {
        c.saveGState(); defer { c.restoreGState() }
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        c.addEllipse(in: rect); c.clip()
        let colors = [CGColor(gray: 0.98, alpha: 1), CGColor(gray: 0.62, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
        c.drawRadialGradient(gradient, startCenter: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.35), startRadius: 0,
                             endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
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
