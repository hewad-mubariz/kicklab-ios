import XCTest
@testable import kicklab

final class SavedDistanceTestTimelineTests: XCTestCase {
    private func data(_ rows: [[String: Any]]) throws -> Data {
        Data(try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n").utf8)
    }

    private func row(_ event: String, _ time: Double, _ x: Any, trial: Int = 1) -> [String: Any] {
        ["event": event, "time_s": time, "world_contact_m": [x, 0, 0], "plane_id": "floor",
         "trial": trial, "distance_calibration": "uncalibrated_ar_floor", "floor_frozen_at_start": true,
         "live": false]
    }

    func testAllSevenRecordingsMatchTheAuditedExperimentAndPreserveSavedReadings() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "saved-distance-replay-test", withExtension: "json"))
        let clips = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(clips.count, 7)
        for clip in clips {
            let rows = try XCTUnwrap(clip["rows"] as? [[String: Any]])
            let log = try data(rows)
            let test = try XCTUnwrap(SavedDistanceTestTimeline.decode(log))
            let saved = try XCTUnwrap(BallDistanceTimeline.decode(log, calibrationID: nil))
            XCTAssertEqual(try XCTUnwrap(test.finalDistanceM), try XCTUnwrap(clip["expected_test_m"] as? Double),
                           accuracy: 0.000_01, clip["time"] as? String ?? "")
            XCTAssertEqual(try XCTUnwrap(saved.finalDistanceM), try XCTUnwrap(clip["expected_saved_m"] as? Double), accuracy: 0.000_01)
            // Backwards seeking must return an earlier observation, not a running maximum.
            for sample in test.samples {
                XCTAssertEqual(test.state(at: sample.time).distanceM, sample.distanceM)
            }
            XCTAssertNotEqual(test.state(at: 100).status, .finished)
        }
    }

    func testLargeStepsAndLongGapsResumeOnlyAtARealSavedPosition() throws {
        let test = try XCTUnwrap(SavedDistanceTestTimeline.decode(data([
            row("set_start", 1, 0), row("sample", 1.1, 4),
            ["event": "sample", "time_s": 1.2, "trial": 1], row("sample", 4, 10),
            ["event": "end", "last_distance_from_start_m": 90]])))
        XCTAssertNil(test.state(at: 0).distanceM)
        XCTAssertEqual(test.state(at: 1.1).distanceM, 4)
        XCTAssertEqual(test.state(at: 2).distanceM, 4)
        XCTAssertEqual(test.state(at: 2).status, .paused)
        XCTAssertEqual(test.state(at: 4).distanceM, 10)
        XCTAssertEqual(test.state(at: 1).distanceM, 0)
        XCTAssertEqual(test.state(at: 5).status, .paused)
    }

    func testChangedCameraFloorOrTrialCannotBeBridgedAndANewStartResets() throws {
        for change: [String: Any] in [["floor_frozen_at_start": false], ["plane_id": "other"],
                                      ["trial": 2], ["distance_calibration": "measured_span_floor_offset"]] {
            var changed = row("sample", 0.2, 6); changed.merge(change) { _, new in new }
            let test = try XCTUnwrap(SavedDistanceTestTimeline.decode(data([
                row("set_start", 0, 0), row("sample", 0.1, 1), changed, row("sample", 0.3, 10),
                row("set_start", 1, 5, trial: 2), row("sample", 1.1, 7, trial: 2)])))
            XCTAssertNil(test.state(at: 0.2).distanceM)
            XCTAssertEqual(test.state(at: 0.3).status, .needsSetup)
            XCTAssertEqual(test.state(at: 1).distanceM, 0)
            XCTAssertEqual(test.state(at: 1.1).distanceM, 2)
        }
    }

    func testMalformedPositionsCannotBecomeDistances() throws {
        let test = try XCTUnwrap(SavedDistanceTestTimeline.decode(data([
            row("set_start", 0, 0), row("sample", 0.1, true), row("sample", 0.2, 1e100),
            row("sample", 0.3, "12"), row("sample", 0.4, 2)])))
        XCTAssertEqual(test.state(at: 0.3).distanceM, 0)
        XCTAssertEqual(test.state(at: 0.3).status, .paused)
        XCTAssertEqual(test.finalDistanceM, 2)
    }

    func testLoadRejectsAlteredEvidenceWithoutWritingTheOriginal() throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("roll-distance.jsonl")
        let log = try data([row("set_start", 0, 0), row("sample", 0.1, 8)])
        try log.write(to: path)
        try JSONSerialization.data(withJSONObject: ["roll_distance": "roll-distance.jsonl",
            "roll_distance_sha256": try ShotRecordingStore.hash(path)])
            .write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try SavedDistanceTestTimeline.load(directory: folder).test?.finalDistanceM, 8)
        XCTAssertEqual(try Data(contentsOf: path), log)
        try data([row("set_start", 0, 0), row("sample", 0.1, 80)]).write(to: path)
        XCTAssertThrowsError(try SavedDistanceTestTimeline.load(directory: folder))
    }
}
