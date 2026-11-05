import XCTest
@testable import kicklab

/// The real detection model reading real videos, as the phone does after a
/// session. The videos are too large for the repo, so this runs only when
/// TEST_RUNNER_STREAK_FOOTAGE names a folder holding them.
final class StreakAbsenceRealModelTests: XCTestCase {
    private struct Case: Decodable { let video, expect: String; let before, after: Int }
    private struct File: Decodable { let cases: [Case] }
    private enum LiveMiss { case ball, playerAndBall }

    private func footage() throws -> (folder: URL, cases: [Case]) {
        guard let folder = ProcessInfo.processInfo.environment["STREAK_FOOTAGE"] else {
            throw XCTSkip("Set TEST_RUNNER_STREAK_FOOTAGE to run on real videos")
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "streak-absence-footage", withExtension: "json"))
        return (URL(fileURLWithPath: folder), try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases)
    }

    /// Pretends the live detector saw nothing, and lets the saved video decide.
    private func assess(_ item: Case, folder: URL, worker: RFWorker, missed: LiveMiss) -> (StreakVisibilityEvidence.Assessment, String?) {
        var evidence = StreakVisibilityEvidence()
        for time in stride(from: item.before+50, to: item.after, by: 100) {
            evidence.record(timeMS: time, personVisible: missed == .ball, ballVisible: false)
        }
        // The simulator is far slower than a phone, and the point here is what the model sees.
        let verifier = SavedStreakVisibilityVerifier(source: folder.appendingPathComponent(item.video), worker: worker, secondsAllowed: 300)
        let result = evidence.assess(touchTimes: [Double(item.before)/1000, Double(item.after)/1000], existingBoundaries: [], recheck: verifier.check)
        return (result, verifier.failure)
    }

    @MainActor func testTheModelFindsTheBallDuringRealJuggling() throws {
        let (folder, cases) = try footage()
        let worker = try RFWorker(resources: XCTUnwrap(Bundle.main.resourceURL))
        BallSkinMetalRenderer.observeApplication()
        let valid = cases.filter { $0.expect == "keep" }
        XCTAssertGreaterThanOrEqual(valid.count, 20)
        var saved = 0
        for item in valid {
            let (result, failure) = assess(item, folder: folder, worker: worker, missed: .ball)
            print("STREAKMODEL keep ball", item.video, item.before, item.after, "ended", result.decisions.count, "overruled", result.absencesOverruled, "frames", result.recheckedFrames, failure ?? "")
            XCTAssertNil(failure, item.video)
            XCTAssertGreaterThanOrEqual(result.recheckedFrames, StreakVisibilityEvidence.secondLookFrames, item.video)
            XCTAssertTrue(result.decisions.isEmpty, "\(item.video) \(item.before): the model missed the ball for all of a real juggling stretch")
            saved += result.absencesOverruled
        }
        XCTAssertEqual(saved, valid.count)
    }

    @MainActor func testTheModelFindsThePlayerDuringRealJuggling() throws {
        let (folder, cases) = try footage()
        let worker = try RFWorker(resources: XCTUnwrap(Bundle.main.resourceURL))
        BallSkinMetalRenderer.observeApplication()
        for item in cases where item.expect == "keep" {
            let (result, failure) = assess(item, folder: folder, worker: worker, missed: .playerAndBall)
            print("STREAKMODEL keep person", item.video, item.before, item.after, "kinds", result.decisions.map(\.kind.rawValue), "frames", result.recheckedFrames, failure ?? "")
            XCTAssertNil(failure, item.video)
            XCTAssertGreaterThanOrEqual(result.recheckedFrames, StreakVisibilityEvidence.secondLookFrames, item.video)
            XCTAssertFalse(result.decisions.contains { $0.kind == .playerOutOfView }, "\(item.video) \(item.before)")
        }
    }

    @MainActor func testTheModelConfirmsARealExit() throws {
        let (folder, cases) = try footage()
        let worker = try RFWorker(resources: XCTUnwrap(Bundle.main.resourceURL))
        BallSkinMetalRenderer.observeApplication()
        for item in cases where item.expect == "end" {
            let (result, failure) = assess(item, folder: folder, worker: worker, missed: .ball)
            print("STREAKMODEL end", item.video, item.before, item.after, "kinds", result.decisions.map(\.kind.rawValue), "overruled", result.absencesOverruled, "frames", result.recheckedFrames, failure ?? "")
            XCTAssertNil(failure, item.video)
            XCTAssertEqual(result.decisions.map(\.kind), [.ballOutOfView], "\(item.video) \(item.before)")
        }
    }
}
