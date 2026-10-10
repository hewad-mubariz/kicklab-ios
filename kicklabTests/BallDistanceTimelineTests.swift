import XCTest
@testable import kicklab

final class BallDistanceTimelineTests: XCTestCase {
    private let calibration: [String: Any] = ["event": "calibration", "calibration_id": "measured", "reference_distance_m": 3]
    private let start: [String: Any] = ["event": "set_start", "time_s": 0,
        "distance_calibration": "measured_span_floor_offset"]

    private func sample(_ time: Double, _ value: Any) -> [String: Any] {
        ["event": "sample", "time_s": time, "distance_from_start_m": value, "live": true,
         "calibration_id": "measured", "distance_calibration": "measured_span_floor_offset",
         "inside_current_mapped_boundary": true]
    }
    private func data(_ rows: [[String: Any]]) throws -> Data {
        var output = Data()
        for row in rows { output.append(try JSONSerialization.data(withJSONObject: row)); output.append(10) }
        return output
    }
    private func timeline(_ rows: [[String: Any]]) throws -> BallDistanceTimeline? {
        try BallDistanceTimeline.decode(data(rows), calibrationID: "measured", sourceOrigin: 1_000)
    }

    func testAnUncalibratedVideoHasNoDistanceEvenWhenTheManifestHadAnEstimate() throws {
        XCTAssertNil(try timeline([start, sample(0.1, 3.2), ["event": "end", "last_distance_from_start_m": 3.2]]))
        XCTAssertNil(try timeline([["event": "calibration", "calibration_id": "other", "reference_distance_m": 3],
            start, sample(0.1, 3.2)]))
    }

    func testReplayUsesObservedDistancesAndPausesAcrossAnUnsupportedGap() throws {
        let result = try XCTUnwrap(timeline([calibration, start, sample(0.1, 0.3), sample(0.8, 1.2)]))
        XCTAssertNil(result.state(at: -0.1).distanceM)
        XCTAssertEqual(result.state(at: 0.2).distanceM, 0.3)
        XCTAssertEqual(result.state(at: 0.6).distanceM, 0.3, "Do not interpolate an unobserved distance")
        XCTAssertEqual(result.state(at: 0.6).status, .paused)
        XCTAssertEqual(result.state(at: 0.8).distanceM, 1.2)
    }

    func testHeldDisplayAndEndFieldsCannotInventANewEndpoint() throws {
        let result = try XCTUnwrap(timeline([calibration, start, sample(0.1, 0.5),
            ["event": "sample", "time_s": 0.2, "live": false, "last_display_distance_m": 99],
            ["event": "end", "last_distance_from_start_m": 99]]))
        XCTAssertEqual(result.state(at: 0.2).distanceM, 0.5)
        XCTAssertEqual(result.state(at: 0.2).status, .paused)
        XCTAssertEqual(result.finalDistanceM, 0.5)
    }

    func testCalibrationLossSuppressesOldScaleAndLaterStaleValues() throws {
        let result = try XCTUnwrap(timeline([calibration, start, sample(0.1, 0.5),
            ["event": "calibration_invalidated", "capture_timestamp_s": 1_001.5],
            sample(1.7, 4.2), ["event": "end", "last_distance_from_start_m": 4.2]]))
        XCTAssertEqual(result.state(at: 1.4).distanceM, 0.5)
        XCTAssertNil(result.state(at: 1.5).distanceM)
        XCTAssertEqual(result.state(at: 1.8).status, .needsSetup)
        XCTAssertNil(result.finalDistanceM)
    }

    func testInvalidNumericTypesAndWrongCalibrationSamplesPauseInsteadOfMeasuring() throws {
        var other = sample(0.3, 9); other["calibration_id"] = "other"
        let result = try XCTUnwrap(timeline([calibration, start, sample(0.1, true), sample(0.2, -1), other]))
        XCTAssertEqual(result.finalDistanceM, 0)
        XCTAssertEqual(result.state(at: 0.3).status, .paused)
        XCTAssertNil(result.state(at: .nan).distanceM)
    }

    func testASecondIntentionalStartResetsDistanceOnTheSavedClock() throws {
        var second = start; second["time_s"] = 1.0
        let result = try XCTUnwrap(timeline([calibration, start, sample(0.1, 2.0), second, sample(1.1, 0.2)]))
        XCTAssertEqual(result.state(at: 0.1).distanceM, 2.0)
        XCTAssertEqual(result.state(at: 1).distanceM, 0)
        XCTAssertEqual(result.state(at: 1.1).distanceM, 0.2)
    }

    func testFileDigestIsCheckedAndTheOriginalEvidenceIsKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = try data([calibration, start, sample(0.1, 0.8)])
        let file = folder.appendingPathComponent("roll-distance.jsonl")
        try rows.write(to: file)
        let photo = folder.appendingPathComponent("roll-calibration.png")
        try Data([1, 2, 3, 4]).write(to: photo)
        var manifest: [String: Any] = ["roll_calibration_id": "measured", "roll_distance": "roll-distance.jsonl",
            "roll_distance_sha256": "changed", "source_origin_s": 1_000,
            "roll_calibration_image": "roll-calibration.png", "roll_calibration_image_sha256": try ShotRecordingStore.hash(photo)]
        let manifestFile = folder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        XCTAssertThrowsError(try BallDistanceTimeline.load(directory: folder))
        XCTAssertEqual(try Data(contentsOf: file), rows)
        manifest["roll_distance_sha256"] = try ShotRecordingStore.hash(file)
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        XCTAssertEqual(try BallDistanceTimeline.load(directory: folder)?.finalDistanceM, 0.8)
        try Data([5, 6]).write(to: photo)
        XCTAssertThrowsError(try BallDistanceTimeline.load(directory: folder))
    }

    func testLatestSavedControlKeepsItsOriginalDistanceAndStartTime() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rolling-distance-saved-control", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try XCTUnwrap(fixture["rows"] as? [[String: Any]])
        let id = try XCTUnwrap(fixture["calibration_id"] as? String)
        let result = try XCTUnwrap(BallDistanceTimeline.decode(data(rows), calibrationID: id))
        XCTAssertNil(result.state(at: 3).distanceM)
        XCTAssertEqual(try XCTUnwrap(result.state(at: 3.5180507079930976).distanceM), 0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.finalDistanceM), 2.2871201038360596, accuracy: 0.000_001)
        XCTAssertEqual(result.state(at: 15).status, .finished)
    }
}
