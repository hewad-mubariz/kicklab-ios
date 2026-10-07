import Foundation
import XCTest
@testable import kicklab

final class ShotRecordingStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func fixture(_ id: String, date: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("original movie bytes".utf8).write(to: folder.appendingPathComponent("video.mov"))
        let row = "{\"tracking_state\":\"normal\",\"world_from_camera\":[[0,1,0,0],[-1,0,0,0],[0,0,1,0],[0,0,0,1]]}\n"
        try Data(row.utf8).write(to: folder.appendingPathComponent("frames.jsonl"))
        var manifest: [String: Any] = [
            "schema": "kicklab.shot-geometry.v1", "video": "video.mov", "frames": "frames.jsonl",
            "recorded_frames": 1, "limited_tracking_frames": 0,
            "video_sha256": try ShotRecordingStore.hash(folder.appendingPathComponent("video.mov")),
            "frames_sha256": try ShotRecordingStore.hash(folder.appendingPathComponent("frames.jsonl"))
        ]
        if let date { manifest["recorded_at"] = date }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        return folder
    }

    func testRelaunchDiscoversMultipleRecordingsIncludingLegacy() throws {
        _ = try fixture("old-format")
        _ = try fixture("take-one", date: "2026-10-02T12:00:00Z")
        _ = try fixture("take-two", date: "2026-10-02T12:01:00Z")
        let firstLoad = try ShotRecordingStore.load(root: root)
        let newLoad = try ShotRecordingStore.load(root: root)
        XCTAssertEqual(firstLoad.recordings.map(\.id), newLoad.recordings.map(\.id))
        XCTAssertEqual(Set(newLoad.recordings.map(\.id)), ["old-format", "take-one", "take-two"])
        XCTAssertEqual(newLoad.incompleteCount, 0)
        let dated = newLoad.recordings.filter { $0.id != "old-format" }
        XCTAssertEqual(dated.map(\.id), ["take-two", "take-one"])
    }

    func testPartialOrMissingDataIsNotOfferedAsSavedAndIsKept() throws {
        let partial = try fixture("partial")
        let missing = try fixture("missing")
        try FileManager.default.removeItem(at: partial.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: missing.appendingPathComponent("frames.jsonl"))
        let library = try ShotRecordingStore.load(root: root)
        XCTAssertTrue(library.recordings.isEmpty)
        XCTAssertEqual(library.incompleteCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.appendingPathComponent("video.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.appendingPathComponent("video.mov").path))
    }

    func testExportCreatesZIPAndKeepsSourceBytes() throws {
        let folder = try fixture("complete")
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        let names = ["video.mov", "frames.jsonl", "manifest.json"]
        let before = try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        let archive = try ShotRecordingStore.export(recording, to: root.appendingPathComponent("exports"))
        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        for name in names { XCTAssertNotNil(bytes.range(of: Data(name.utf8))) }
        XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, before)
        XCTAssertEqual(try ShotRecordingStore.previewRotation(recording), 90)
    }

    func testExportRejectsChangedMeasurementData() throws {
        let folder = try fixture("modified")
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        try Data("changed after save".utf8).write(to: folder.appendingPathComponent("frames.jsonl"))
        XCTAssertThrowsError(try ShotRecordingStore.export(recording, to: root.appendingPathComponent("exports")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.video.path))
    }

    private func rollFixture() throws -> URL {
        let folder = try fixture("roll-test")
        let path = folder.appendingPathComponent("roll-distance.jsonl")
        try Data("{\"event\":\"sample\",\"distance_from_start_m\":1.23,\"physical_scale_verified\":false}\n".utf8).write(to: path)
        let manifest = folder.appendingPathComponent("manifest.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        data["roll_distance"] = "roll-distance.jsonl"
        data["roll_distance_sha256"] = try ShotRecordingStore.hash(path)
        data["roll_distance_last_estimate_m"] = 1.23
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        return folder
    }

    func testRollEstimateSurvivesRelaunchAndExportIncludesItsObservations() throws {
        let folder = try rollFixture()
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        XCTAssertEqual(recording.lastRollEstimateM ?? -1, 1.23, accuracy: 0.001)
        let original = try Data(contentsOf: folder.appendingPathComponent("roll-distance.jsonl"))
        let archive = try ShotRecordingStore.export(recording, to: root.appendingPathComponent("exports"))
        XCTAssertNotNil(try Data(contentsOf: archive).range(of: Data("roll-distance.jsonl".utf8)))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("roll-distance.jsonl")), original)
    }

    func testExportRejectsChangedRollObservations() throws {
        let folder = try rollFixture()
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        try Data("tampered\n".utf8).write(to: folder.appendingPathComponent("roll-distance.jsonl"))
        XCTAssertThrowsError(try ShotRecordingStore.export(recording, to: root.appendingPathComponent("exports")))
    }

    func testMissingRollDataIsNotOfferedAsComplete() throws {
        let folder = try rollFixture()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("roll-distance.jsonl"))
        let library = try ShotRecordingStore.load(root: root)
        XCTAssertTrue(library.recordings.isEmpty)
        XCTAssertEqual(library.incompleteCount, 1)
    }

    func testLegacyRecordingsDoNotAcquireInventedRollEstimates() throws {
        _ = try fixture("legacy")
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        XCTAssertNil(recording.lastRollEstimateM)
        XCTAssertNil(recording.peakRollingSpeedKMH)
    }

    private func calibrationFixture() throws -> URL {
        let folder = try rollFixture()
        let image = folder.appendingPathComponent("roll-calibration.png")
        try Data("calibration pixels fixture".utf8).write(to: image)
        let manifest = folder.appendingPathComponent("manifest.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        data["roll_calibration_image"] = "roll-calibration.png"
        data["roll_calibration_image_sha256"] = try ShotRecordingStore.hash(image)
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        return folder
    }

    func testCalibrationPhotoSurvivesExportAndIsVerified() throws {
        let folder = try calibrationFixture()
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        let archive = try ShotRecordingStore.export(recording, to: root.appendingPathComponent("exports"))
        XCTAssertNotNil(try Data(contentsOf: archive).range(of: Data("roll-calibration.png".utf8)))
        try Data("changed calibration photo".utf8).write(to: folder.appendingPathComponent("roll-calibration.png"))
        XCTAssertThrowsError(try ShotRecordingStore.export(recording, to: root.appendingPathComponent("other-exports")))
    }

    func testMissingCalibrationPhotoCannotBeOfferedAsComplete() throws {
        let folder = try calibrationFixture()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("roll-calibration.png"))
        let library = try ShotRecordingStore.load(root: root)
        XCTAssertTrue(library.recordings.isEmpty)
        XCTAssertEqual(library.incompleteCount, 1)
    }

    func testRollingSpeedPeakSurvivesRelaunchAndVerifiedExport() throws {
        let folder = try calibrationFixture()
        let manifest = folder.appendingPathComponent("manifest.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        data["roll_speed_peak_estimate_kmh"] = 2.8
        data["roll_speed_physical_scale_verified"] = false
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        let recording = try XCTUnwrap(ShotRecordingStore.load(root: root).recordings.first)
        XCTAssertEqual(recording.peakRollingSpeedKMH ?? -1, 2.8, accuracy: 0.001)
        let original = try Data(contentsOf: manifest)
        let archive = try ShotRecordingStore.export(recording, to: root.appendingPathComponent("exports"))
        XCTAssertNotNil(try Data(contentsOf: archive).range(of: Data("manifest.json".utf8)))
        XCTAssertEqual(try Data(contentsOf: manifest), original)
    }

    func testImpossibleOrUncalibratedSpeedPeakCannotBeOfferedAsComplete() throws {
        let folder = try calibrationFixture()
        let manifest = folder.appendingPathComponent("manifest.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        for speed in [-1.0, 50.0] {
            data["roll_speed_peak_estimate_kmh"] = speed
            try JSONSerialization.data(withJSONObject: data).write(to: manifest)
            XCTAssertTrue(try ShotRecordingStore.load(root: root).recordings.isEmpty)
        }
        data["roll_speed_peak_estimate_kmh"] = 2.8
        data.removeValue(forKey: "roll_calibration_image")
        data.removeValue(forKey: "roll_calibration_image_sha256")
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        XCTAssertTrue(try ShotRecordingStore.load(root: root).recordings.isEmpty)
    }
}
