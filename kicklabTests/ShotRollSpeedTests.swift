import XCTest
import simd
@testable import kicklab

final class ShotRollSpeedTests: XCTestCase {
    func testKnownVelocityUsesCaptureTimeDespiteIrregularSamplesAndLongWait() throws {
        var speed = ShotRollSpeedEstimator()
        for i in 0...30 { speed.observe(point: .zero, time: 900_000 + Double(i) * 0.1) }
        XCTAssertEqual(speed.speedKMH, 0)
        for t in [0.1, 0.19, 0.31, 0.42, 0.50, 0.61, 0.71, 0.80, 0.91, 1.02] {
            speed.observe(point: SIMD3(Float(t) * 1.2, 0, 0), time: 900_003 + t)
        }
        XCTAssertEqual(try XCTUnwrap(speed.speedKMH), 4.32, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(speed.peakKMH), 4.32, accuracy: 0.001)
    }

    func testStationaryJitterReturnsZeroAndDoesNotInventPeak() {
        var speed = ShotRollSpeedEstimator()
        for i in 0...100 {
            speed.observe(point: SIMD3(i % 2 == 0 ? 0.005 : -0.005, 0, -2), time: Double(i) / 10)
        }
        XCTAssertEqual(speed.speedKMH, 0)
        XCTAssertEqual(speed.peakKMH, 0)
    }

    func testStoppedBallReturnsZeroAndRetainsPeakUntilNewStart() throws {
        var tracker = ShotRollTracker()
        tracker.arm(point: .zero, time: 0)
        for i in 1...10 {
            XCTAssertTrue(tracker.observe(point: SIMD3(Float(i) / 10, 0, 0), time: Double(i) / 10))
        }
        XCTAssertEqual(try XCTUnwrap(tracker.speed.speedKMH), 3.6, accuracy: 0.001)
        for i in 11...20 { XCTAssertTrue(tracker.observe(point: SIMD3(1, 0, 0), time: Double(i) / 10)) }
        XCTAssertEqual(tracker.speed.speedKMH, 0)
        XCTAssertEqual(try XCTUnwrap(tracker.speed.peakKMH), 3.6, accuracy: 0.001)
        tracker.arm(point: SIMD3(1, 0, 0), time: 2.1)
        XCTAssertNil(tracker.speed.speedKMH)
        XCTAssertNil(tracker.speed.peakKMH)
    }

    func testDiagonalAndReturningMotionUseVelocityRatherThanOriginDisplacement() throws {
        var tracker = ShotRollTracker()
        tracker.arm(point: .zero, time: 0)
        for i in 1...10 {
            XCTAssertTrue(tracker.observe(point: SIMD3(Float(i) * 0.06, 0, Float(i) * 0.08), time: Double(i) / 10))
        }
        XCTAssertEqual(try XCTUnwrap(tracker.speed.speedKMH), 3.6, accuracy: 0.001)
        for i in 11...20 {
            let t = Float(20 - i) / 10
            XCTAssertTrue(tracker.observe(point: SIMD3(t * 0.6, 0, t * 0.8), time: Double(i) / 10))
        }
        XCTAssertEqual(tracker.distanceM, 0)
        XCTAssertEqual(try XCTUnwrap(tracker.speed.speedKMH), 3.6, accuracy: 0.001)
    }

    func testUnclearMotionAndFastMotionDoNotProduceSpeed() {
        var noisy = ShotRollSpeedEstimator(), fast = ShotRollSpeedEstimator()
        for i in 0...6 {
            noisy.observe(point: SIMD3(Float(i) * 0.1, i == 3 ? 0.25 : 0, 0), time: Double(i) / 10)
            fast.observe(point: SIMD3(Float(i) * 0.7, 0, 0), time: Double(i) / 10)
        }
        XCTAssertNil(noisy.speedKMH); XCTAssertNil(noisy.peakKMH)
        XCTAssertTrue(noisy.status.contains("unclear"))
        XCTAssertNil(fast.speedKMH); XCTAssertNil(fast.peakKMH)
        XCTAssertTrue(fast.status.contains("too fast"))
    }

    func testGapDuplicateAndNonfiniteSamplesRequireFreshMotion() throws {
        var speed = ShotRollSpeedEstimator()
        for i in 0...6 { speed.observe(point: SIMD3(Float(i) * 0.1, 0, 0), time: Double(i) / 10) }
        speed.observe(point: SIMD3(1, 0, 0), time: 1)
        XCTAssertNil(speed.speedKMH)
        for i in 11...16 { speed.observe(point: SIMD3(Float(i) / 10, 0, 0), time: Double(i) / 10) }
        XCTAssertEqual(try XCTUnwrap(speed.speedKMH), 3.6, accuracy: 0.001)
        speed.observe(point: SIMD3(1.6, 0, 0), time: 1.6)
        XCTAssertNil(speed.speedKMH)
        speed.observe(point: SIMD3(.nan, 0, 0), time: 1.7)
        XCTAssertNil(speed.speedKMH)
        XCTAssertEqual(speed.sampleCount, 0)
    }

    func testTrackingInvalidationClearsSpeedAndPeakWithoutChangingDistanceGuard() throws {
        for nextTime in [0.7, 2.0] {
            var tracker = ShotRollTracker()
            tracker.arm(point: .zero, time: 0)
            for i in 1...6 { XCTAssertTrue(tracker.observe(point: SIMD3(Float(i) * 0.1, 0, 0), time: Double(i) / 10)) }
            XCTAssertNotNil(tracker.speed.speedKMH)
            XCTAssertFalse(tracker.observe(point: SIMD3(8, 0, 0), time: nextTime))
            XCTAssertTrue(tracker.needsNewStart)
            XCTAssertNil(tracker.speed.speedKMH); XCTAssertNil(tracker.speed.peakKMH)
            XCTAssertEqual(try XCTUnwrap(tracker.distanceM), 0.6, accuracy: 0.001)
        }
        var display = ShotRollDisplay()
        display.speedKMH = 3; display.peakRollingSpeedKMH = 4
        display.markCalibrationLost("Camera moved")
        XCTAssertNil(display.speedKMH); XCTAssertNil(display.peakRollingSpeedKMH)
    }

    func testSavedTwoMetreRollsHaveSupportedMotionAndZeroAtRest() throws {
        struct Sample: Decodable { let t: Double; let point: [Float] }
        struct Clip: Decodable { let id: String; let start: Sample; let samples: [Sample]; let peakRange: [Float]; let endpointM: Float }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rolling-speed-controls", withExtension: "json"))
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: file))
        XCTAssertEqual(clips.count, 2)
        for clip in clips {
            var tracker = ShotRollTracker()
            func point(_ sample: Sample) -> SIMD3<Float> { SIMD3(sample.point[0], sample.point[1], sample.point[2]) }
            tracker.arm(point: point(clip.start), time: clip.start.t)
            var liveValues: [Float] = []
            for sample in clip.samples {
                XCTAssertTrue(tracker.observe(point: point(sample), time: sample.t), clip.id)
                if let value = tracker.speed.speedKMH { liveValues.append(value) }
            }
            XCTAssertGreaterThan(liveValues.count, 50)
            let peak = try XCTUnwrap(tracker.speed.peakKMH)
            XCTAssertGreaterThan(peak, clip.peakRange[0]); XCTAssertLessThan(peak, clip.peakRange[1])
            XCTAssertEqual(tracker.speed.speedKMH, 0)
            XCTAssertEqual(try XCTUnwrap(tracker.distanceM), clip.endpointM, accuracy: 0.001)
        }
    }
}
