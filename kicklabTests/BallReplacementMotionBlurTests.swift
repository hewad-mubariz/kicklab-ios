import CoreVideo
import XCTest
@testable import kicklab

final class BallReplacementMotionBlurTests: XCTestCase {
    private let size = CGSize(width: 720, height: 1280)

    private var body: BallReplacementFootprint {
        .init(sourceSize: size, center: CGPoint(x: 360, y: 640), radius: 50,
              radii: Array(repeating: 50, count: 64), feather: 1, padding: 0)
    }

    private func photographed(smear: Double, clutter: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 720, 1280, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        memset(bytes, 60, CVPixelBufferGetDataSize(pixels))
        for y in 550..<730 { for x in 270..<450 {
            var alpha = 0.0
            // Independently integrate the photographed circle during exposure.
            for step in 0..<80 {
                let offset = smear * ((Double(step) + 0.5) / 80 - 0.5)
                if hypot(Double(x) + 0.5 - 360, Double(y) + 0.5 - 640 - offset) < 50 { alpha += 1.0 / 80 }
            }
            let background = clutter ? Double((x * 73 + y * 131) % 180 + 30) : 60
            let colour = UInt8((alpha * 230 + (1 - alpha) * background).rounded())
            let p = bytes + y * stride + x * 4
            p[0] = colour; p[1] = colour; p[2] = colour; p[3] = 255
        } }
        return pixels
    }

    func testPhotographedBlurCorrectsAnUnderestimateButDoesNotInventBlurOnSharpEdges() throws {
        let blurred = try XCTUnwrap(BallReplacementMotionBlur.measured(pixels: photographed(smear: 18),
            body: body, suggested: CGVector(dx: 0, dy: 8)))
        XCTAssertEqual(blurred.dx, 0, accuracy: 0.001)
        XCTAssertEqual(blurred.dy, 18, accuracy: 3)
        XCTAssertNil(BallReplacementMotionBlur.measured(pixels: try photographed(smear: 0),
            body: body, suggested: CGVector(dx: 0, dy: 8)), "Antialiasing alone must not establish exposure")
        XCTAssertNil(BallReplacementMotionBlur.measured(pixels: try photographed(smear: 18, clutter: true),
            body: body, suggested: CGVector(dx: 0, dy: 8)))
    }

    func testCalibrationNeedsRepeatedConsistentEvidenceAndStaysWithinFrameDuration() throws {
        var calibration = BallExposureCalibration(duration: 30, frameDuration: 1.0 / 60)
        XCTAssertTrue(calibration.shouldMeasure(at: 0))
        XCTAssertFalse(calibration.shouldMeasure(at: 0.01))
        for i in 0..<7 {
            calibration.observe(time: Double(i) / 4, smear: CGVector(dx: 0, dy: 18), velocity: CGVector(dx: 0, dy: 1000))
        }
        XCTAssertNil(calibration.estimate)
        calibration.observe(time: 2, smear: CGVector(dx: 0, dy: 18), velocity: CGVector(dx: 0, dy: 1000))
        XCTAssertEqual(try XCTUnwrap(calibration.estimate), 1.0 / 60, accuracy: 1e-12)
        var mixed = BallExposureCalibration(duration: 30, frameDuration: 1.0 / 60)
        for i in 0..<20 {
            mixed.observe(time: Double(i) / 4, smear: CGVector(dx: 0, dy: i % 2 == 0 ? 3 : 19),
                          velocity: CGVector(dx: 0, dy: 1000))
        }
        XCTAssertNil(mixed.estimate, "Changing/inconsistent source evidence must keep the established fallback")
    }

    func testSemanticOwnershipDoesNotMakeMeasuredBlurOpaqueOrCoverTheFinger() {
        let width = 120
        let binary = (0..<(width * width)).map { i -> UInt8 in
            let x = Double(i % width) + 0.5 - 60, y = Double(i / width) + 0.5 - 60
            return hypot(x, y) < 50 && !(x > 30 && abs(y) < 10) ? 255 : 0
        }
        let mask = BallMask(rect: CGRect(x: 300.0 / 720, y: 580.0 / 1280, width: 120.0 / 720, height: 120.0 / 1280),
            width: width, height: width, alpha: BallMask.featheredCoverage(binary, width: width, height: width))
        let smear = CGVector(dx: 0, dy: 18)
        let prior = BallReplacementCoverage(mask: mask, fitted: body, size: size, smear: smear)
        let corrected = BallReplacementCoverage(mask: mask, fitted: body, size: size, smear: smear, photographicSmear: true)
        let edge = corrected.footprint.center.y + corrected.footprint.radius - 2
        XCTAssertGreaterThan(prior.coverage(x: 360, y: edge), 0.95)
        XCTAssertGreaterThan(corrected.coverage(x: 360, y: edge), 0.4)
        XCTAssertLessThan(corrected.coverage(x: 360, y: edge), 0.85)
        XCTAssertEqual(corrected.coverage(x: 402, y: 640), 0, accuracy: 0.001)
        XCTAssertEqual(corrected.footprint.center, prior.footprint.center)
        XCTAssertEqual(corrected.footprint.radius, prior.footprint.radius)
    }

    func testCalibratedExposureKeepsTheSameTrackAndSamplesDeterministicallyAfterSeeking() {
        let frames = (0..<40).map { i in
            RecordedFrame(time: Double(i) / 60, x: 0.3 + Double(i) / 60 * 0.3, y: 0.5,
                width: 0.1, height: 72.0 / 1280, score: 1, smoothedX: 0, smoothedY: 0,
                vy: 0, motion: .unknown, detected: true, person: nil)
        }
        let baseline = BallEffectTrack(frames: frames)
        var track = baseline
        track.surfaceMotion = BallSurfaceTimeline(entries: [], elapsed: 0, photographicExposure: 1.0 / 120)
        for time in [0.2, 0.4, 0.1, 0.2] {
            XCTAssertEqual(track.smear(at: time, size: size).dx, 1.8, accuracy: 1e-8)
            XCTAssertEqual(track.smear(at: time, size: size).dy, 0, accuracy: 1e-8)
            XCTAssertEqual(track.sample(at: time)?.center, baseline.sample(at: time)?.center)
            XCTAssertEqual(track.sample(at: time)?.boxSize, baseline.sample(at: time)?.boxSize)
        }
    }
}
