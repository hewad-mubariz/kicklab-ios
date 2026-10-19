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

    func testActualRFCurrentFrameCropRepairsUndercoverageWithoutMovingTrack() throws {
        let original = try fixture(), size = CGSize(width: 720, height: 1280)
        let request = try XCTUnwrap(RFMaskCropRefiner.requests(frames: [original], frameDuration: 1.0 / 60).first)
        let roi = try XCTUnwrap(RFMaskCropRefiner.region(request, size: size))
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rf-mask-crop-current", withExtension: "png"))
        let image = try XCTUnwrap(CIImage(contentsOf: url))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 720, 1280, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CIContext(options: [.workingColorSpace: NSNull()]).render(image, to: pixels)
        let detector = try BallDetector(resourceName: RFSmallModel.fp16.rawValue, rfResolution: .detailed)
        let candidate = try detector.inferRFMaskCrop(pixels, roi: roi)
        let repaired = try XCTUnwrap(RFMaskCropRefiner.accepted(candidate, request: request, roi: roi, size: size),
            "Candidate: \(String(describing: candidate.ball)); mask area: \(candidate.ballMask.map(RFMaskCropRefiner.area) ?? 0); original area: \(RFMaskCropRefiner.area(original.ballMask!)); ROI: \(roi)")
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
            let roi = try XCTUnwrap(RFMaskCropRefiner.region(request, size: size))
            let imageURL = try XCTUnwrap(bundle.url(forResource: "hand-mask-gap-\(index)", withExtension: "jpg"))
            let image = try XCTUnwrap(CIImage(contentsOf: imageURL))
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 720, 1280, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            context.render(image, to: pixels)
            let candidate = try detector.inferRFMaskCrop(pixels, roi: roi)
            if let mask = RFMaskCropRefiner.accepted(candidate, request: request, roi: roi, size: size) {
                let hand = index == 101 ? CGPoint(x: 370, y: 902) : CGPoint(x: 370, y: 818)
                XCTAssertLessThan(mask.coverage(x: hand.x / 720, y: hand.y / 1280), 0.25)
            }
            context.render(CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4))
                .cropped(to: CGRect(origin: .zero, size: size)), to: pixels)
            XCTAssertNil(RFMaskCropRefiner.accepted(try detector.inferRFMaskCrop(pixels, roi: roi),
                request: request, roi: roi, size: size))
        }
    }

    func testLowConfidenceWrongObjectAndShrunkenMasksAreRejected() throws {
        let f = try fixture(), size = CGSize(width: 720, height: 1280)
        let request = RFMaskCropRefiner.Request(time: f.time, guide: f, index: 0)
        let roi = try XCTUnwrap(RFMaskCropRefiner.region(request, size: size))
        for b in [Detection(score: 0.7, x: f.x, y: f.y, width: f.width, height: f.height),
                  Detection(score: 0.99, x: f.x + 0.2, y: f.y, width: f.width, height: f.height),
                  Detection(score: 0.99, x: f.x, y: f.y, width: f.width * 2, height: f.height * 2)] {
            XCTAssertNil(RFMaskCropRefiner.accepted(FrameDetections(ball: b, person: nil,
                ballMask: f.ballMask, usesBallMasks: true), request: request, roi: roi, size: size))
        }
        // An unchanged or shrinking mask is not a coverage improvement.
        XCTAssertNil(RFMaskCropRefiner.accepted(FrameDetections(ball: Detection(score: 0.99,
            x: f.x, y: f.y, width: f.width, height: f.height), person: nil, ballMask: f.ballMask,
            usesBallMasks: true), request: request, roi: roi, size: size))
    }
}
