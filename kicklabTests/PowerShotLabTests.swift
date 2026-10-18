#if POWER_SHOT_DEBUG
import XCTest
@testable import kicklab

final class PowerShotLabTests: XCTestCase {
    func testEvidenceCaptureRequiresCameraButNotFloorBallOrCalibration() {
        XCTAssertTrue(PowerShotCapturePolicy.canCaptureEvidence(cameraActive: true, hasFrame: true, calibrating: false))
        XCTAssertFalse(PowerShotCapturePolicy.canCaptureEvidence(cameraActive: false, hasFrame: true, calibrating: false))
        XCTAssertFalse(PowerShotCapturePolicy.canCaptureEvidence(cameraActive: true, hasFrame: false, calibrating: false))
        XCTAssertFalse(PowerShotCapturePolicy.canCaptureEvidence(cameraActive: true, hasFrame: true, calibrating: true))
    }

    func testDetectorScheduleExplainsSkippedFramesAtActualCadence() {
        XCTAssertEqual(PowerShotCapturePolicy.detectorSchedule(calibrating: false, busy: true, elapsed: 1, recording: true), "inference_busy")
        XCTAssertEqual(PowerShotCapturePolicy.detectorSchedule(calibrating: true, busy: false, elapsed: 1, recording: true), "calibration_photo_open")
        XCTAssertEqual(PowerShotCapturePolicy.detectorSchedule(calibrating: false, busy: false, elapsed: 0.099, recording: true), "cadence_limit")
        XCTAssertEqual(PowerShotCapturePolicy.detectorSchedule(calibrating: false, busy: false, elapsed: 0.1, recording: true), "submit")
        XCTAssertEqual(PowerShotCapturePolicy.detectorSchedule(calibrating: false, busy: false, elapsed: 0.1, recording: false), "cadence_limit")
    }

    func testSameShotRetainsIndependentRawAndCorrectedProjectionTraces() {
        var diagnostics = PowerShotDiagnostics()
        var start: [String: Any] = ["event": "set_start", "capture_timestamp_s": 100.0,
            "world_contact_m": [Float(1), 0, 0], "uncalibrated_world_contact_m": [Float(0.5), 0, 0]]
        diagnostics.annotate(&start)
        var sample: [String: Any] = ["event": "sample", "capture_timestamp_s": 100.1,
            "world_contact_m": [Float(3), 0, 0], "uncalibrated_world_contact_m": [Float(1.5), 0, 0]]
        diagnostics.annotate(&sample)
        XCTAssertEqual(sample["raw_ground_projection_distance_m"] as? Double, 2)
        XCTAssertEqual(sample["uncalibrated_distance_from_start_m"] as? Double, 1)
        XCTAssertNil(sample["rolling_speed_kmh"])
        XCTAssertEqual(sample["raw_projection_is_validated_measurement"] as? Bool, false)
    }

    func testPenaltyReferenceIsNominalAndDoesNotInventEndpointOrSpeed() throws {
        var reference = PowerShotFieldReference()
        reference.penalty = PowerShotPenaltyReference()
        XCTAssertEqual(reference.penalty?.goalLineDistanceM, "11")
        XCTAssertEqual(reference.penalty?.distanceSource, "regulation_nominal")
        XCTAssertTrue(reference.endpointMetres.isEmpty)
        XCTAssertTrue(reference.referenceSpeedKMH.isEmpty)
        XCTAssertNil(reference.validationError)
        reference.penalty?.releaseTimeS = "5"
        reference.penalty?.crossingTimeS = "4"
        XCTAssertNotNil(reference.validationError)
        reference.penalty?.crossingTimeS = "5,6"
        reference.penalty?.lateralOffsetM = "-2.3"
        XCTAssertNil(reference.validationError)
        reference.penalty?.crossingHeightM = "nan"
        XCTAssertNotNil(reference.validationError)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PowerShotFieldReference())) as? [String: Any])
        legacy.removeValue(forKey: "penalty")
        let decoded = try JSONDecoder().decode(PowerShotFieldReference.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.penalty, "Existing on-phone notes must remain readable after upgrading")
    }

    func testMovementRejectionRecordsAttemptAndPreservesLastAcceptedValue() throws {
        var tracker = ShotRollTracker()
        tracker.arm(point: .zero, time: 100)
        XCTAssertTrue(tracker.observe(point: SIMD3(0.1, 0, 0), time: 100.1))
        XCTAssertFalse(tracker.observe(point: SIMD3(1, 0, 0), time: 100.2))
        XCTAssertEqual(tracker.debugRejection, "movement_limit")
        XCTAssertEqual(try XCTUnwrap(tracker.debugStep["tracker_step_m"]), 0.9, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(tracker.debugStep["tracker_step_limit_m"]), 0.72, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(tracker.distanceM), 0.1, accuracy: 0.00001)
        XCTAssertTrue(tracker.needsNewStart)
        XCTAssertNil(tracker.speed.speedKMH)
    }

    func testGapIsDistinctFromMovementLimitAndRearmClearsReason() {
        var tracker = ShotRollTracker()
        tracker.arm(point: .zero, time: 100)
        XCTAssertTrue(tracker.observe(point: SIMD3(0.2, 0, 0), time: 100.1))
        XCTAssertFalse(tracker.observe(point: SIMD3(0.21, 0, 0), time: 101))
        XCTAssertEqual(tracker.debugRejection, "observation_gap")
        tracker.arm(point: .zero, time: 102)
        XCTAssertNil(tracker.debugRejection)
        XCTAssertTrue(tracker.debugStep.isEmpty)
    }

    func testRawEvidenceContinuesAfterRejectionWithoutClaimingMeasurement() throws {
        var diagnostics = PowerShotDiagnostics()
        var start: [String: Any] = ["event": "set_start", "world_contact_m": [0.0, 0.0, 0.0], "capture_timestamp_s": 100.0]
        diagnostics.annotate(&start)
        diagnostics.lastInvalidation = "movement_limit"
        var sample: [String: Any] = ["event": "sample", "world_contact_m": [2.0, 0.0, 0.0],
                                   "capture_timestamp_s": 100.1, "live": false, "last_display_distance_m": 0.0]
        diagnostics.annotate(&sample)
        XCTAssertEqual(sample["raw_ground_projection_distance_m"] as? Double, 2)
        XCTAssertEqual(sample["raw_projection_is_validated_measurement"] as? Bool, false)
        XCTAssertEqual(sample["live"] as? Bool, false)
        XCTAssertEqual(sample["last_display_distance_m"] as? Double, 0)
        XCTAssertNil(sample["distance_from_start_m"])
        XCTAssertNil(sample["rolling_speed_kmh"])
        XCTAssertEqual(sample["last_invalidation_reason"] as? String, "movement_limit")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: sample))
    }

    func testMissingAndNonfiniteProjectionsDoNotCreateDistance() {
        var diagnostics = PowerShotDiagnostics()
        for point in [[], [Double.nan, 0, 0]] {
            var sample: [String: Any] = ["event": "sample", "world_contact_m": point, "capture_timestamp_s": 100.0]
            diagnostics.annotate(&sample)
            XCTAssertNil(sample["raw_ground_projection_distance_m"])
            XCTAssertNil(sample["raw_projection_speed_kmh"])
        }
    }

    func testReferenceRequiresNumericValuesAndExplicitMethods() {
        var reference = PowerShotFieldReference()
        for value in ["nan", "inf", "-1", "unknown"] {
            reference.endpointMetres = value
            XCTAssertNotNil(reference.validationError)
        }
        reference.endpointMetres = "2,50"
        XCTAssertNotNil(reference.validationError)
        reference.distanceMethod = "tape"
        XCTAssertNil(reference.validationError)
        reference.referenceSpeedKMH = "7.2"
        XCTAssertNotNil(reference.validationError)
        reference.speedMethod = "timed_markers"
        XCTAssertNil(reference.validationError)
    }

    func testFieldNotesSurviveRelaunchAndExportWithoutChangingSensorEvidence() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("trial")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = folder.appendingPathComponent("video.mov"), frames = folder.appendingPathComponent("frames.jsonl")
        try Data("fixture video".utf8).write(to: video)
        try Data("fixture frames".utf8).write(to: frames)
        let manifest: [String: Any] = ["schema": "kicklab.shot-geometry.v1", "video": "video.mov",
            "frames": "frames.jsonl", "recorded_frames": 1, "limited_tracking_frames": 0,
            "video_sha256": try ShotRecordingStore.hash(video), "frames_sha256": try ShotRecordingStore.hash(frames)]
        let manifestURL = folder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let before = try ShotRecordingStore.hash(manifestURL)
        var reference = PowerShotFieldReference()
        reference.endpointMetres = "5.04"; reference.distanceMethod = "tape"; reference.notes = "Ball stopped"
        try reference.save(to: folder)
        XCTAssertEqual(try PowerShotFieldReference.load(from: folder).notes, "Ball stopped")
        XCTAssertEqual(try ShotRecordingStore.hash(manifestURL), before)
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        let zip = try ShotRecordingStore.export(recording, to: root.appendingPathComponent("exports"))
        XCTAssertNotNil(try Data(contentsOf: zip).range(of: Data(PowerShotFieldReference.filename.utf8)))
    }
}
#endif
