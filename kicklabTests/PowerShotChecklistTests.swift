#if POWER_SHOT_DEBUG
import XCTest
@testable import kicklab

@MainActor
final class PowerShotChecklistTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func store() -> PowerShotChecklistStore {
        PowerShotChecklistStore(sessionURL: root.appendingPathComponent("session.json"), recordingsRoot: root.appendingPathComponent("recordings"))
    }
    private func step(_ id: String) -> PowerShotChecklistStep { PowerShotChecklistStep.all.first { $0.id == id }! }
    private func fixture(_ reference: PowerShotFieldReference, complete: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent("recordings/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try reference.save(to: folder)
        let video = folder.appendingPathComponent("video.mov"), frames = folder.appendingPathComponent("frames.jsonl")
        try Data("test-original-video".utf8).write(to: video)
        try Data("test-original-frames".utf8).write(to: frames)
        if complete {
            let manifest: [String: Any] = ["schema": "kicklab.shot-geometry.v1", "video": "video.mov", "frames": "frames.jsonl",
                "recorded_frames": 1, "limited_tracking_frames": 0,
                "video_sha256": try ShotRecordingStore.hash(video), "frames_sha256": try ShotRecordingStore.hash(frames)]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        }
        return folder
    }

    func testSelectionSetupGapsAndContextPersistWithoutInventingCompletion() throws {
        let first = store()
        first.confirmSetup(step("setup"))
        XCTAssertEqual(first.selected.id, "calibration")
        first.setGap("No measured calibration marks", for: step("calibration"))
        first.select(step("penalty_low"))
        var setup = PowerShotFieldReference(); setup.surface = "Grass, sun, tripod"
        first.saveSetupReference(setup)
        let second = store()
        XCTAssertEqual(first.session.id, second.session.id)
        XCTAssertEqual(second.selected.id, "penalty_low")
        XCTAssertEqual(second.completedCount, 1)
        XCTAssertFalse(second.complete(step("calibration")))
        XCTAssertEqual(second.session.gaps["calibration"], "No measured calibration marks")
        XCTAssertEqual(second.session.setupReference?.surface, "Grass, sun, tripod")
    }

    func testCaptureLinkIsUniqueAndDoesNotCarryPriorOutcomeOrClaimedReference() {
        let store = store(); store.select(step("penalty_low"))
        var base = PowerShotFieldReference()
        base.penalty = PowerShotPenaltyReference(); base.penalty?.goalLineDistanceM = "10.9"
        base.penalty?.distanceSource = "tape"; base.penalty?.crossingTimeS = "4"
        base.endpointMetres = "20"; base.referenceSpeedKMH = "50"
        base.checklistReview = PowerShotChecklistReview(visibilityConfirmed: true)
        let first = store.referenceForCapture(base), second = store.referenceForCapture(base)
        XCTAssertEqual(first.checklist?.sessionID, store.session.id)
        XCTAssertEqual(first.checklist?.stepID, "penalty_low")
        XCTAssertNotEqual(first.checklist?.attemptID, second.checklist?.attemptID)
        XCTAssertNil(first.checklistReview)
        XCTAssertTrue(first.endpointMetres.isEmpty)
        XCTAssertTrue(first.referenceSpeedKMH.isEmpty)
        XCTAssertEqual(first.penalty?.goalLineDistanceM, "10.9")
        XCTAssertEqual(first.penalty?.crossingTimeS, "")
        store.select(step("stationary"))
        XCTAssertNil(store.referenceForCapture(base).penalty)
    }

    func testSavedAndIncompleteClipsDoNotCompleteStepUntilReviewed() async throws {
        let store = store(); store.select(step("stationary"))
        let first = store.referenceForCapture(PowerShotFieldReference())
        let firstFolder = try fixture(first)
        let secondFolder = try fixture(store.referenceForCapture(PowerShotFieldReference()))
        _ = try fixture(store.referenceForCapture(PowerShotFieldReference()), complete: false)
        await store.reload()
        XCTAssertEqual(store.clips.count, 2)
        XCTAssertEqual(store.incomplete.count, 1)
        XCTAssertEqual(store.unreviewedCount, 2)
        XCTAssertFalse(store.complete(step("stationary")))
        for folder in [firstFolder, secondFolder] {
            var reference = try PowerShotFieldReference.load(from: folder)
            reference.checklistReview = PowerShotChecklistReview(visibilityConfirmed: true)
            try reference.save(to: folder)
        }
        await store.reload()
        XCTAssertTrue(store.complete(step("stationary")))
        let relaunched = self.store(); await relaunched.reload()
        XCTAssertEqual(relaunched.reviewedCount(step("stationary")), 2)
        relaunched.setGap("Need a farther stationary position", for: step("stationary"))
        XCTAssertFalse(relaunched.complete(step("stationary")))
        relaunched.setGap("", for: step("stationary"))
        XCTAssertTrue(relaunched.complete(step("stationary")))
    }

    func testRetakesAndOtherSessionsAreRetainedButNeverCounted() async throws {
        let store = store(); store.select(step("stationary"))
        var retake = store.referenceForCapture(PowerShotFieldReference())
        retake.checklistReview = PowerShotChecklistReview(disposition: "retake", visibilityConfirmed: true, reason: "Blurred")
        _ = try fixture(retake)
        var other = retake; other.checklist?.sessionID = UUID()
        _ = try fixture(other)
        await store.reload()
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertEqual(store.reviewedCount(step("stationary")), 0)
        XCTAssertTrue(store.clips[0].missingEvidence(for: step("stationary"))!.contains("Blurred"))
    }

    func testDistanceReferenceCannotBeAppEstimateOrNominalMark() async throws {
        let store = store(); store.select(step("roll_1m"))
        var reference = store.referenceForCapture(PowerShotFieldReference())
        reference.checklistReview = PowerShotChecklistReview(visibilityConfirmed: true)
        let folder = try fixture(reference)
        await store.reload()
        XCTAssertEqual(store.reviewedCount(step("roll_1m")), 0)
        reference.endpointMetres = "1.08"; reference.distanceMethod = "apple_measure"; reference.notes = "Stopped at end mark"
        try reference.save(to: folder); await store.reload()
        XCTAssertEqual(store.reviewedCount(step("roll_1m")), 0)
        reference.distanceMethod = "tape"
        try reference.save(to: folder); await store.reload()
        XCTAssertEqual(store.reviewedCount(step("roll_1m")), 1)
        XCTAssertFalse(store.complete(step("roll_1m")), "Three repeats are required")
    }

    func testNominalPenaltyCoverageRetainsExplicitIndependentReferenceGap() async throws {
        let store = store(); store.select(step("penalty_low"))
        var reference = store.referenceForCapture(PowerShotFieldReference())
        reference.checklistReview = PowerShotChecklistReview(visibilityConfirmed: true)
        _ = try fixture(reference)
        await store.reload()
        XCTAssertEqual(store.reviewedCount(step("penalty_low")), 1)
        XCTAssertEqual(store.nominalPenaltyCount, 1)
        XCTAssertEqual(store.clips[0].reference.penalty?.distanceSource, "regulation_nominal")
        XCTAssertTrue(store.clips[0].reference.endpointMetres.isEmpty)
    }

    func testMissingOrCorruptStateNeverOverwritesExistingEvidence() throws {
        let file = root.appendingPathComponent("session.json")
        let bytes = Data("interrupted-or-unknown-data".utf8)
        try bytes.write(to: file)
        let store = store()
        XCTAssertFalse(store.available)
        store.select(step("stationary"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertNotNil(store.error)
    }

    func testExportIncludesChecklistEveryAttemptAndIncompleteFilesWithoutChangingOriginals() async throws {
        let store = store(); store.select(step("stationary"))
        var reference = store.referenceForCapture(PowerShotFieldReference())
        reference.checklistReview = PowerShotChecklistReview(disposition: "retake", reason: "Ball left view")
        let folder = try fixture(reference)
        let original = try ShotRecordingStore.hash(folder.appendingPathComponent("manifest.json"))
        _ = try fixture(store.referenceForCapture(PowerShotFieldReference()), complete: false)
        await store.reload()
        let zip = try await store.export()
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let data = try Data(contentsOf: zip)
        for name in ["checklist-session.json", "protocol.json", "evidence-summary.json", "Incomplete-unverified", "Power-Shot-\(folder.lastPathComponent).zip"] {
            XCTAssertNotNil(data.range(of: Data(name.utf8)), "Missing \(name)")
        }
        XCTAssertEqual(try ShotRecordingStore.hash(folder.appendingPathComponent("manifest.json")), original)
        XCTAssertFalse(store.session.backupConfirmed, "Preparing a share is not confirmation of a backup")
    }

    func testChangedSensorEvidenceBlocksExport() async throws {
        let store = store(); store.select(step("stationary"))
        let folder = try fixture(store.referenceForCapture(PowerShotFieldReference()))
        await store.reload()
        try Data("modified".utf8).write(to: folder.appendingPathComponent("video.mov"))
        do { _ = try await store.export(); XCTFail("Changed originals must not export as verified") }
        catch { XCTAssertTrue(error is ShotRecordingStore.StoreError) }
    }

    func testUnreadableReferencesClearStaleCountsAndBlockPartialExport() async throws {
        let store = store(); store.select(step("stationary"))
        var reference = store.referenceForCapture(PowerShotFieldReference())
        reference.checklistReview = PowerShotChecklistReview(visibilityConfirmed: true)
        let folder = try fixture(reference)
        await store.reload()
        XCTAssertEqual(store.reviewedCount(step("stationary")), 1)
        try Data("broken notes".utf8).write(to: folder.appendingPathComponent(PowerShotFieldReference.filename))
        await store.reload()
        XCTAssertEqual(store.reviewedCount(step("stationary")), 0)
        XCTAssertNotNil(store.error)
        do { _ = try await store.export(); XCTFail("Do not silently export an incomplete checklist") }
        catch { XCTAssertTrue(error is ShotRecordingStore.StoreError) }
    }
}
#endif
