import AVFoundation
import XCTest
@testable import kicklab

/// For now a submission uploads clips of its flagged moments. The windows must match
/// what scripts/review-leaderboard.py rebuilds, and the clips must fit the upload limit.
final class LeaderboardMomentClipsTests: XCTestCase {
    private let proposal = RankedStreakProposal(count: 18, startMS: 500, endMS: 28_000)

    private func moment(_ kind: LeaderboardReviewMoment.Kind, at time: Int, duration: Int = 30_000) -> LeaderboardReviewMoment {
        LeaderboardReviewMoment(kind: kind, timeMS: time, lastTimeMS: time,
                                clipStartMS: max(0, time - 1_000), clipEndMS: min(duration, time + 1_200))
    }

    func testOverlappingMomentsShareOneClipLikeTheReviewTool() {
        let windows = LeaderboardMomentClips.windows(
            for: [moment(.handsUncertain, at: 5_000), moment(.continuityGap, at: 5_800), moment(.groundContact, at: 29_500)],
            proposal: proposal, durationMS: 30_000)
        // The same input gives [[4000, 7000], [28500, 30000]] in the review tool.
        XCTAssertEqual(windows, [.init(startMS: 4_000, endMS: 7_000), .init(startMS: 28_500, endMS: 30_000)])
    }

    func testNoFlagsSendsTheStreaksFirstAndLastSeconds() {
        let windows = LeaderboardMomentClips.windows(
            for: [], proposal: .init(count: 18, startMS: 500, endMS: 29_500), durationMS: 30_000)
        XCTAssertEqual(windows, [.init(startMS: 0, endMS: 1_700), .init(startMS: 28_300, endMS: 30_000)])
    }

    func testTrimmingKeepsMomentsInsideTheStreakAndSplitsFirst() {
        let order = LeaderboardMomentClips.prioritized([
            moment(.handsUncertain, at: 29_000), moment(.ballUncertain, at: 9_000),
            moment(.groundContact, at: 12_000), moment(.handContact, at: 29_500)
        ], proposal: proposal)
        XCTAssertEqual(order.map(\.timeMS), [12_000, 9_000, 29_500, 29_000])
    }

    func testClipsAreCutFromTheRecordingAndReusedForAResume() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moment-clips-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = UUID()
        let durationMS = Int((try await AVURLAsset(url: source).load(.duration).seconds * 1000).rounded())
        let review = LeaderboardTouchReview(version: 1, durationMS: durationMS, complete: true,
            moments: [moment(.handsUncertain, at: 3_000, duration: durationMS), moment(.groundContact, at: 9_000, duration: durationMS)])
        let streak = RankedStreakProposal(count: 10, startMS: 1_000, endMS: durationMS - 1_000)

        let prepared = try await LeaderboardMomentClips.prepare(source: source, review: review, proposal: streak,
            durationMS: durationMS, folder: folder, session: session, limit: LeaderboardRules.maximumVideoBytes)
        XCTAssertEqual(prepared.review, review, "Everything fits, so every moment is sent")
        let clipped = try await AVURLAsset(url: prepared.file).load(.duration).seconds
        XCTAssertEqual(clipped, 4.4, accuracy: 0.25, "Two 2.2 s windows, not the whole recording")
        let sourceBytes = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let clipBytes = try XCTUnwrap(prepared.file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(clipBytes, sourceBytes)

        let first = try LeaderboardVideoFingerprint.read(prepared.file).sha256
        let resumed = try await LeaderboardMomentClips.prepare(source: source, review: review, proposal: streak,
            durationMS: durationMS, folder: folder, session: session, limit: LeaderboardRules.maximumVideoBytes)
        XCTAssertEqual(try LeaderboardVideoFingerprint.read(resumed.file).sha256, first,
                       "A resumed upload must send the bytes the attempt was registered with")

        LeaderboardMomentClips.remove(folder: folder, session: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.file.path))
    }

    func testTooManyMomentsAreTrimmedToFitAndMarkedIncomplete() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moment-clips-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let durationMS = Int((try await AVURLAsset(url: source).load(.duration).seconds * 1000).rounded())
        let moments = stride(from: 1_500, to: durationMS - 1_500, by: 3_000).map {
            moment($0 == 7_500 ? .groundContact : .handsUncertain, at: $0, duration: durationMS)
        }
        let review = LeaderboardTouchReview(version: 1, durationMS: durationMS, complete: true, moments: moments)
        let streak = RankedStreakProposal(count: 10, startMS: 1_000, endMS: durationMS - 1_000)
        // Find what everything costs, then allow roughly half of it.
        let full = try await LeaderboardMomentClips.prepare(source: source, review: review, proposal: streak,
            durationMS: durationMS, folder: folder, session: UUID(), limit: LeaderboardRules.maximumVideoBytes)
        let fullBytes = Int64(try XCTUnwrap(full.file.resourceValues(forKeys: [.fileSizeKey]).fileSize))

        let trimmed = try await LeaderboardMomentClips.prepare(source: source, review: review, proposal: streak,
            durationMS: durationMS, folder: folder, session: UUID(), limit: fullBytes / 2)
        let kept = try XCTUnwrap(trimmed.review)
        XCTAssertFalse(kept.complete)
        XCTAssertLessThan(kept.moments.count, moments.count)
        XCTAssertTrue(kept.moments.contains { $0.kind == .groundContact }, "A streak split earns its place first")
        let bytes = Int64(try XCTUnwrap(trimmed.file.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        XCTAssertLessThanOrEqual(bytes, fullBytes / 2)
    }
}
