import CoreImage
import XCTest
@testable import kicklab

@MainActor
final class RFMaskCropRefinerTests: XCTestCase {
    private func fixture() throws -> RecordedFrame {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rf-mask-crop-current", withExtension: "json"))
        let row = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let v = row["values"] as! [Double], m = row["mask"] as! [String: Any], r = m["rect"] as! [Double]
        let mask = BallMask(rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
            width: m["width"] as! Int, height: m["height"] as! Int,
            alpha: Array(Data(base64Encoded: m["alpha"] as! String)!))
        return RecordedFrame(time: v[0], x: v[1], y: v[2], width: v[3], height: v[4], score: v[5],
            smoothedX: v[6], smoothedY: v[7], vy: v[8], motion: .unknown, detected: true,
            person: nil, ballMask: mask, usesBallMasks: true)
    }

    private func recover(_ pixels: CVPixelBuffer, request: RFMaskCropRefiner.Request,
                         detector: BallDetector, size: CGSize) throws -> BallMask? {
        var candidates = [RFMaskCropConsensus.Candidate](), visited = [CGRect]()
        for context in RFMaskCropConsensus.contexts {
            guard let roi = RFMaskCropRefiner.region(request, size: size, context: context), !visited.contains(roi) else { continue }
            visited.append(roi)
            let found = try detector.inferRFMaskCrop(pixels, roi: roi)
            if let candidate = RFMaskCropConsensus.candidate(found, guide: request.guide, roi: roi, size: size) {
                candidates.append(candidate)
                if visited.count == 1, let mask = RFMaskCropConsensus.conservativeAddition(candidate, guide: request.guide) { return mask }
            }
            if let mask = RFMaskCropConsensus.accepted(candidates, guide: request.guide) { return mask }
        }
        return nil
    }

    func testActualRFCurrentFrameCropRepairsUndercoverageWithoutMovingTrack() throws {
        let original = try fixture(), size = CGSize(width: 720, height: 1280)
        let request = try XCTUnwrap(RFMaskCropRefiner.requests(frames: [original], frameDuration: 1.0 / 60).first)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rf-mask-crop-current", withExtension: "png"))
        let image = try XCTUnwrap(CIImage(contentsOf: url))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 720, 1280, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CIContext(options: [.workingColorSpace: NSNull()]).render(image, to: pixels)
        let detector = try BallDetector(resourceName: RFSmallModel.fp16.rawValue, rfResolution: .detailed)
        let repaired = try XCTUnwrap(recover(pixels, request: request, detector: detector, size: size))
        XCTAssertGreaterThan(RFMaskCropRefiner.area(repaired), RFMaskCropRefiner.area(original.ballMask!) * 1.15)
        XCTAssertEqual(repaired.alphaSum, repaired.expanded().alphaSum)
        var visual = original; visual.ballMask = repaired
        let before = BallEffectTrack(frames: [original]), after = BallEffectTrack(frames: [visual])
        XCTAssertEqual(before.samples.map(\.center), after.samples.map(\.center))
        XCTAssertEqual(before.samples.map(\.boxSize), after.samples.map(\.boxSize))
        XCTAssertEqual(before.samples.map(\.time), after.samples.map(\.time))
        XCTAssertNil(after.mask(at: original.time + 0.004), "No mask borrowing from another exposure")
    }

    func testPlannerCapsWorkAndNeverUsesRepairsAsAnchors() throws {
        let f = try fixture()
        let frames = (0..<3_000).map { i in
            RecordedFrame(time: Double(i) / 60, x: f.x, y: f.y, width: f.width, height: f.height,
                score: f.score, smoothedX: f.x, smoothedY: f.y, vy: 0, motion: .unknown,
                detected: true, person: nil, ballMask: f.ballMask, usesBallMasks: true)
        }
        let work = RFMaskCropRefiner.requests(frames: frames, frameDuration: 1.0 / 60)
        XCTAssertEqual(work.count, 240)
        XCTAssertEqual(RFMaskCropRefiner.modelCallBudget(frameCount: frames.count), 240)
        XCTAssertGreaterThan(work.last!.time, 49)
        var repaired = f; repaired.isVisualMaskRepair = true
        XCTAssertTrue(RFMaskCropRefiner.requests(frames: [repaired], frameDuration: 1.0 / 60).isEmpty)
        var recovered = f; recovered.isVisualRecovery = true
        XCTAssertTrue(RFMaskCropRefiner.requests(frames: [recovered], frameDuration: 1.0 / 60).isEmpty)
    }

    func testRealHandOcclusionsRemainUnpaintedAndCoveredBallIsNotInvented() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "hand-mask-gap-anchors", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        func anchor(_ index: Int) throws -> RecordedFrame {
            let row = try XCTUnwrap(rows.first { $0["frame"] as? Int == index })
            let b = row["ball"] as! [Double]
            return RecordedFrame(time: row["time"] as! Double, x: b[1], y: b[2], width: b[3], height: b[4],
                score: b[0], smoothedX: b[1], smoothedY: b[2], vy: 0, motion: .unknown, detected: true, person: nil)
        }
        let detector = try BallDetector(resourceName: RFSmallModel.fp16.rawValue, rfResolution: .detailed)
        let context = CIContext(options: [.workingColorSpace: NSNull()]), size = CGSize(width: 720, height: 1280)
        for index in [101, 106] {
            let a = try anchor(index - 1), b = try anchor(index + 1)
            let guide = RecordedFrame(time: (a.time + b.time) / 2, x: (a.x + b.x) / 2, y: (a.y + b.y) / 2,
                width: (a.width + b.width) / 2, height: (a.height + b.height) / 2, score: min(a.score, b.score),
                smoothedX: a.x, smoothedY: a.y, vy: 0, motion: .unknown, detected: true, person: nil)
            let request = RFMaskCropRefiner.Request(time: guide.time, guide: guide, index: nil)
            let imageURL = try XCTUnwrap(bundle.url(forResource: "hand-mask-gap-\(index)", withExtension: "jpg"))
            let image = try XCTUnwrap(CIImage(contentsOf: imageURL))
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 720, 1280, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            context.render(image, to: pixels)
            if let mask = try recover(pixels, request: request, detector: detector, size: size) {
                let hand = index == 101 ? CGPoint(x: 370, y: 902) : CGPoint(x: 370, y: 818)
                XCTAssertLessThan(mask.coverage(x: hand.x / 720, y: hand.y / 1280), 0.25)
            }
            context.render(CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4))
                .cropped(to: CGRect(origin: .zero, size: size)), to: pixels)
            XCTAssertNil(try recover(pixels, request: request, detector: detector, size: size))
        }
    }

    func testLowConfidenceWrongObjectAndSingleContextAreRejected() throws {
        let f = try fixture(), size = CGSize(width: 720, height: 1280)
        let request = RFMaskCropRefiner.Request(time: f.time, guide: f, index: 0)
        let roi = try XCTUnwrap(RFMaskCropRefiner.region(request, size: size))
        for b in [Detection(score: 0.7, x: f.x, y: f.y, width: f.width, height: f.height),
                  Detection(score: 0.99, x: f.x + 0.2, y: f.y, width: f.width, height: f.height),
                  Detection(score: 0.99, x: f.x, y: f.y, width: f.width * 2, height: f.height * 2)] {
            XCTAssertNil(RFMaskCropConsensus.candidate(FrameDetections(ball: b, person: nil,
                ballMask: f.ballMask, usesBallMasks: true), guide: f, roi: roi, size: size))
        }
        // A single confident crop cannot authorize a change in ownership.
        let candidate = try XCTUnwrap(RFMaskCropConsensus.candidate(FrameDetections(ball: Detection(score: 0.99,
            x: f.x, y: f.y, width: f.width, height: f.height), person: nil, ballMask: f.ballMask,
            usesBallMasks: true), guide: f, roi: roi, size: size))
        XCTAssertNil(RFMaskCropConsensus.accepted([candidate], guide: f))
    }

    func testConsensusCanRestoreMissingBallAndRemoveFalseFingerOwnership() throws {
        let f = try fixture(), rect = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
        var old = [UInt8](repeating: 255, count: 64 * 64)
        var correct = old
        for y in 0..<64 { for x in 0..<64 {
            if y > 30 { old[y * 64 + x] = 0 } // A lost lower panel.
            if x > 40 && y < 20 { correct[y * 64 + x] = 0 } // A visible finger.
        } }
        var guide = f
        guide.ballMask = BallMask(rect: rect, width: 64, height: 64, alpha: old)
        let mask = BallMask(rect: rect, width: 64, height: 64, alpha: correct)
        let b = Detection(score: 0.99, x: f.x, y: f.y, width: f.width, height: f.height)
        let candidate = RFMaskCropConsensus.Candidate(ball: b, mask: mask)
        let repaired = try XCTUnwrap(RFMaskCropConsensus.accepted([candidate, candidate], guide: guide))
        XCTAssertGreaterThan(repaired.coverage(x: 0.4, y: 0.45), 0.99)
        XCTAssertLessThan(repaired.coverage(x: 0.46, y: 0.33), 0.01)
        XCTAssertEqual(repaired.decoderPixelSize, mask.samplingSize)
        XCTAssertEqual(repaired.compacted().expanded().decoderPixelSize, mask.samplingSize)
        let conflicting = RFMaskCropConsensus.Candidate(ball: b, mask: guide.ballMask!)
        XCTAssertNil(RFMaskCropConsensus.accepted([candidate, conflicting], guide: guide))
    }

    func testLongGapRetriesFollowTheBallsArcAndStayBounded() throws {
        // A ball rising to its apex in front of a white shirt: 10 frames unseen.
        func y(_ t: Double) -> Double { 0.5 - 1.2 * t + 3 * t * t }
        func frame(_ index: Int) -> RecordedFrame {
            let t = Double(index) / 60, rect = CGRect(x: 0.45, y: y(t) - 0.028, width: 0.1, height: 0.056)
            return RecordedFrame(time: t, x: 0.5, y: y(t), width: 0.1, height: 0.056, score: 0.95,
                smoothedX: 0.5, smoothedY: y(t), vy: 0, motion: .unknown, detected: true, person: nil,
                ballMask: BallMask(rect: rect, width: 20, height: 20, alpha: Array(repeating: 255, count: 400)), usesBallMasks: true)
        }
        let frames = (0...30).filter { !(11...20).contains($0) }.map(frame)
        let long = RFMaskCropRefiner.longGaps(frames: frames, frameDuration: 1.0 / 60)
        XCTAssertEqual(long.map { Int(($0.time * 60).rounded()) }, Array(11...20))
        XCTAssertTrue(long.allSatisfy { $0.index == nil && $0.guide.isVisualMaskRepair && !$0.requiresConsensus })
        let middle = try XCTUnwrap(long.first { abs($0.time - 15.0 / 60) < 0.001 })
        let straight = y(10.0 / 60) + (y(21.0 / 60) - y(10.0 / 60)) * 5 / 11
        XCTAssertLessThan(abs(middle.guide.y - y(0.25)), abs(straight - y(0.25)) / 3)
        // The full planner retries them; flow-sized gaps keep their own path.
        let planned = RFMaskCropRefiner.requests(frames: frames, frameDuration: 1.0 / 60)
        XCTAssertEqual(planned.filter { $0.index == nil }.count, 10)
        XCTAssertTrue(RFMaskCropRefiner.longGaps(frames: (0...30).filter { !(11...13).contains($0) }.map(frame), frameDuration: 1.0 / 60).isEmpty)
        // Too long to be the same flight, or a different object: no retries.
        XCTAssertTrue(RFMaskCropRefiner.longGaps(frames: (0...40).filter { !(3...30).contains($0) }.map(frame), frameDuration: 1.0 / 60).isEmpty)
        var resized = frames; resized[11] = RecordedFrame(time: resized[11].time, x: 0.5, y: 0.5, width: 0.2, height: 0.112, score: 0.95,
            smoothedX: 0.5, smoothedY: 0.5, vy: 0, motion: .unknown, detected: true, person: nil, ballMask: frames[11].ballMask, usesBallMasks: true)
        XCTAssertTrue(RFMaskCropRefiner.longGaps(frames: resized, frameDuration: 1.0 / 60).isEmpty)
    }

    func testPlannerFindsFragmentEvenWhenItsDetectorBoxShrinks() throws {
        let f = try fixture()
        func frame(_ index: Int, small: Bool) -> RecordedFrame {
            let scale = small ? 0.7 : 1.0
            let rect = CGRect(x: f.x - f.width * scale / 2, y: f.y - f.height * scale / 2,
                              width: f.width * scale, height: f.height * scale)
            let alpha = (0..<400).map { UInt8($0 % 20 < 16 ? 255 : 0) }
            return RecordedFrame(time: Double(index) / 60, x: f.x, y: f.y, width: rect.width, height: rect.height,
                score: 0.99, smoothedX: f.x, smoothedY: f.y, vy: 0, motion: .unknown, detected: true,
                person: nil, ballMask: BallMask(rect: rect, width: 20, height: 20, alpha: alpha), usesBallMasks: true)
        }
        let frames = (0..<9).map { frame($0, small: $0 == 4) }
        let pending = RFMaskCropRefiner.requests(frames: frames, frameDuration: 1.0 / 60)
        XCTAssertTrue(pending.contains { $0.index == 4 })
        XCTAssertTrue(pending.first { $0.index == 4 }?.requiresConsensus == true)
        XCTAssertFalse(pending.contains { $0.index == 0 })
        let long = (0..<3_000).map { frame($0, small: $0 % 9 == 4) }
        let bounded = RFMaskCropRefiner.requests(frames: long, frameDuration: 1.0 / 60)
        XCTAssertEqual(bounded.count, 120)
        XCTAssertTrue(bounded.allSatisfy(\.requiresConsensus))
        XCTAssertEqual(bounded.reduce(0) { $0 + $1.minimumCalls }, 240,
            "Long recordings must reserve BOTH required contexts, not240 one-call attempts that can never agree")
        XCTAssertGreaterThan(bounded.last!.time, 49)
    }
}
