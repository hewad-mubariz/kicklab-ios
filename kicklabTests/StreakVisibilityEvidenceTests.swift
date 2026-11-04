import XCTest
@testable import kicklab

final class StreakVisibilityEvidenceTests: XCTestCase {
    private func evidence(_ samples: [StreakVisibilityEvidence.Sample]) -> StreakVisibilityEvidence {
        var evidence = StreakVisibilityEvidence()
        for sample in samples { evidence.record(timeMS: sample.timeMS, personVisible: sample.personVisible) }
        return evidence
    }
    private func samples(_ range: ClosedRange<Int>, step: Int = 250, visible: Bool) -> [StreakVisibilityEvidence.Sample] {
        stride(from: range.lowerBound, through: range.upperBound, by: step)
            .map { .init(timeMS: $0, personVisible: visible) }
    }
    private func assess(_ source: StreakVisibilityEvidence, touches: [Double] = [1, 2, 6, 7],
                        boundaries: [Double] = [], recheck: (StreakVisibilityEvidence.Window) -> [StreakVisibilityEvidence.Sample] = { _ in [] }) -> StreakVisibilityEvidence.Assessment {
        source.assess(touchTimes: touches, existingBoundaries: boundaries, recheck: recheck)
    }

    func testSustainedFreshAbsenceSplitsRunsWithoutChangingTotal() throws {
        let touches = [1.0, 2, 6, 7, 8]
        let result = assess(evidence(samples(2_250...5_750, visible: false)), touches: touches) { _ in
            XCTFail("Fresh absence requires no extra inference"); return []
        }
        XCTAssertEqual(result.decisions.map(\.kind), [.playerOutOfView])
        var review = TouchReviewEvidence()
        for cut in result.decisions { review.append(time: Double(cut.timeMS)/1000, kind: cut.kind) }
        let persisted = try XCTUnwrap(LeaderboardTouchReview.make(evidence: review, touchTimes: touches, duration: 10))
        let restored = try JSONDecoder().decode(LeaderboardTouchReview.self, from: JSONEncoder().encode(persisted))
        let streak = RankedStreakProposal.suggest(touchTimes: touches, boundaries: restored.streakBoundaries, duration: 10)
        XCTAssertEqual(streak?.count, 3)
        XCTAssertEqual(touches.count, 5)
        XCTAssertEqual(restored, persisted)
    }

    func testTwoSecondDepartureWithinLongFlightDoesNotSplit() {
        let observations = samples(2_250...4_250, visible: false) + samples(4_500...5_750, visible: true)
        XCTAssertTrue(assess(evidence(observations)) { _ in XCTFail("Short observed absence"); return [] }.decisions.isEmpty)
    }

    func testTwoSecondDepartureDoesNotBecomeUnverifiedBecauseOfSamplingAtEndpoints() {
        let observations = samples(2_250...4_250, visible: false)
        let result = assess(evidence(observations), touches: [1, 2, 4.5, 5]) { _ in
            XCTFail("Fully observed miss below the grace period"); return []
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testVisiblePlayerWithLongHighKickNeverNeedsBallOrTouchTimeout() {
        let result = assess(evidence(samples(2_250...11_750, visible: true)), touches: [1, 2, 12, 13]) { _ in
            XCTFail("No ball-absence timer or reanalysis for a visible player"); return []
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testLateAndOutOfOrderCallbacksUseSourceTime() {
        let observations = samples(2_250...5_750, visible: true)
        // Delivering the same frames in reverse order represents arbitrary
        // callback delay; only source timestamps are part of the policy.
        let normal = assess(evidence(observations))
        let delayed = assess(evidence(Array(observations.reversed())))
        XCTAssertEqual(normal.decisions, delayed.decisions)
        XCTAssertEqual(delayed.recheckWindows, 0)
    }

    func testNoInferenceIsUnknownAndSavedVisibleFramesRecoverTheRun() {
        let result = assess(evidence([])) { window in
            XCTAssertEqual(window, .init(startMS: 2_000, endMS: 6_000))
            return self.samples(2_250...5_750, step: 500, visible: true)
        }
        XCTAssertEqual(result.recheckWindows, 1)
        XCTAssertTrue(result.decisions.isEmpty, "Analysis lag must not cut a visible run")
    }

    func testSavedFramesCanConfirmARealDepartureDuringAnalysisGap() {
        let result = assess(evidence([])) { _ in self.samples(2_250...5_750, step: 500, visible: false) }
        XCTAssertEqual(result.decisions.map(\.kind), [.playerOutOfView])
        XCTAssertEqual(result.recheckedFrames, 8)
    }

    func testStaleOrSparseNegativeResultsCannotProveDeparture() {
        let source = evidence(samples(2_250...5_250, step: 1_000, visible: false))
        let result = assess(source) { _ in self.samples(2_500...5_500, step: 500, visible: true) }
        XCTAssertEqual(result.recheckWindows, 1)
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testUnreadableSourceIsExplicitlyUnverifiedAndNeverCalledADrop() {
        let result = assess(evidence([]))
        XCTAssertEqual(result.decisions.map(\.kind), [.visibilityUnverified])
        XCTAssertTrue(result.decisions[0].kind.breaksStreak)
        let score = RankedStreakProposal.suggest(touchTimes: [1, 2, 6, 7],
            boundaries: result.decisions.map { Double($0.timeMS)/1000 }, duration: 8)
        XCTAssertEqual(score?.count, 2)
    }

    func testAlreadySeparatedRunsDoNotNeedVideoRecheck() {
        let result = assess(evidence([]), boundaries: [3]) { _ in XCTFail("Already split by a hold/bounce"); return [] }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testRepeatedDeparturesEachSeparateRuns() {
        let source = evidence(samples(2_250...5_750, visible: false) + samples(7_250...10_750, visible: false))
        let result = assess(source, touches: [1, 2, 6, 7, 11, 12, 13])
        XCTAssertEqual(result.decisions.count, 2)
        let score = RankedStreakProposal.suggest(touchTimes: [1, 2, 6, 7, 11, 12, 13],
            boundaries: result.decisions.map { Double($0.timeMS)/1000 }, duration: 15)
        XCTAssertEqual(score?.count, 3)
    }

    func testDuplicatesCannotSupplyIndependentAbsenceEvidence() {
        let source = evidence(Array(repeating: .init(timeMS: 2_250, personVisible: false), count: 40)
            + Array(repeating: .init(timeMS: 5_250, personVisible: false), count: 40))
        XCTAssertEqual(assess(source).decisions.map(\.kind), [.visibilityUnverified])
    }

    func testFreshVisibleObservationResetsAbsenceGrace() {
        let source = evidence(samples(2_250...5_750, visible: false) + [.init(timeMS: 4_000, personVisible: true)])
        XCTAssertTrue(assess(source).decisions.isEmpty)
    }

    func testInvalidTouchTimesAndNoStreakDoNotRequestRechecks() {
        let result = assess(evidence([]), touches: [.nan, .infinity, -1, 1, 1, 90_000]) { _ in
            XCTFail("No pair of valid contacts"); return []
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }
}
