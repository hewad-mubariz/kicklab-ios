import XCTest
@testable import kicklab

/// Rolls measured on ARKit's own floor, with no measured-marks calibration.
final class BallDistanceARFloorTests: XCTestCase {
    private func data(_ rows: [[String: Any]]) throws -> Data {
        Data(try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n").utf8)
    }

    private let start: [String: Any] = ["event": "set_start", "capture_timestamp_s": 1_001.0,
                                        "distance_calibration": "uncalibrated_ar_floor"]
    private func sample(_ offset: Double, _ distance: Double, method: String = "uncalibrated_ar_floor") -> [String: Any] {
        ["event": "sample", "capture_timestamp_s": 1_001.0 + offset, "distance_from_start_m": distance,
         "distance_calibration": method, "live": true, "inside_current_mapped_boundary": true]
    }

    func testARFloorDistancesReplayWithoutCalibration() throws {
        let rows = [start, sample(0.1, 0.4), sample(0.5, 1.6), ["event": "end"]]
        let timeline = try XCTUnwrap(BallDistanceTimeline.decode(data(rows), calibrationID: nil, sourceOrigin: 1_000))
        XCTAssertEqual(timeline.state(at: 1.05).distanceM, 0)
        XCTAssertEqual(timeline.state(at: 1.55).distanceM, 1.6)
        XCTAssertEqual(timeline.finalDistanceM, 1.6)
    }

    func testCalibratedRowsAreNotMixedIntoAnARFloorReplay() throws {
        let rows = [start, sample(0.1, 0.4), sample(0.3, 9, method: "measured_span_floor_offset")]
        let timeline = try XCTUnwrap(BallDistanceTimeline.decode(data(rows), calibrationID: nil, sourceOrigin: 1_000))
        XCTAssertEqual(timeline.state(at: 1.35).distanceM, 0.4, "A sample from another method pauses, it does not measure")
        XCTAssertEqual(timeline.state(at: 1.35).status, .paused)
    }

    func testARecordingWithoutCalibrationLoadsItsDistance() throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("roll-distance.jsonl")
        try data([start, sample(0.2, 0.8)]).write(to: path)
        let manifest: [String: Any] = ["roll_distance": "roll-distance.jsonl", "source_origin_s": 1_000,
                                       "roll_distance_sha256": try ShotRecordingStore.hash(path)]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try BallDistanceTimeline.load(directory: folder)?.finalDistanceM, 0.8)
        try data([start, sample(0.2, 5)]).write(to: path)
        XCTAssertThrowsError(try BallDistanceTimeline.load(directory: folder), "An edited file is rejected")
    }
}
