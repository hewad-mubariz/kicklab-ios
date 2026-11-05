import XCTest
@testable import kicklab

final class StreakVisibilityEvidenceTests: XCTestCase {
    private func evidence(_ samples: [StreakVisibilityEvidence.Sample]) -> StreakVisibilityEvidence {
        var evidence = StreakVisibilityEvidence()
        for sample in samples { evidence.record(timeMS: sample.timeMS, personVisible: sample.personVisible, ballVisible: sample.ballVisible) }
        return evidence
    }
    private func samples(_ range: ClosedRange<Int>, step: Int = 250, visible: Bool, ball: Bool = true) -> [StreakVisibilityEvidence.Sample] {
        stride(from: range.lowerBound, through: range.upperBound, by: step)
            .map { .init(timeMS: $0, personVisible: visible, ballVisible: ball) }
    }
    /// A saved video that shows neither the player nor the ball.
    private func emptyVideo(_ window: StreakVisibilityEvidence.Window) -> [StreakVisibilityEvidence.Sample] {
        stride(from: window.startMS+250, to: window.endMS, by: 500).map { .init(timeMS: $0, personVisible: false, ballVisible: false) }
    }
    private func assess(_ source: StreakVisibilityEvidence, touches: [Double] = [1, 2, 6, 7],
                        boundaries: [Double] = [], recheck: (StreakVisibilityEvidence.Window) -> [StreakVisibilityEvidence.Sample] = { _ in [] }) -> StreakVisibilityEvidence.Assessment {
        source.assess(touchTimes: touches, existingBoundaries: boundaries, recheck: recheck)
    }

    func testSustainedFreshAbsenceSplitsRunsWithoutChangingTotal() throws {
        let touches = [1.0, 2, 6, 7, 8]
        let result = assess(evidence(samples(2_250...5_750, visible: false)), touches: touches, recheck: emptyVideo)
        XCTAssertEqual(result.decisions.map(\.kind), [.playerOutOfView])
        XCTAssertEqual(result.secondLooks, 1)
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

    func testVisiblePlayerAndBallNeverNeedATouchTimeout() {
        let result = assess(evidence(samples(2_250...11_750, visible: true)), touches: [1, 2, 12, 13]) { _ in
            XCTFail("No reanalysis while the player and the ball are in view"); return []
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    // MARK: The limit

    func testTheLimitIsThreeSeconds() {
        XCTAssertEqual(StreakVisibilityEvidence.graceMS, 3_000)
    }

    func testPlayerMissingJustUnderTheLimitKeepsTheStreak() {
        let observations = samples(2_100...5_000, step: 100, visible: false) + samples(5_100...6_000, step: 100, visible: true)
        XCTAssertTrue(assess(evidence(observations)).decisions.isEmpty)
    }

    func testPlayerMissingForTheLimitEndsTheStreak() {
        let observations = samples(2_100...5_100, step: 100, visible: false) + samples(5_200...6_000, step: 100, visible: true)
        XCTAssertEqual(assess(evidence(observations), recheck: emptyVideo).decisions.map(\.kind), [.playerOutOfView])
    }

    func testPlayerSeenInTheSavedVideoOverrulesALiveMiss() {
        let live = samples(2_100...5_900, step: 100, visible: false)
        let result = assess(evidence(live)) { window in
            self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true)
        }
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertEqual(result.absencesOverruled, 1)
    }

    func testUnreadableVideoNeverEndsAStreakForAMissingPlayer() {
        let result = assess(evidence(samples(2_100...5_900, step: 100, visible: false))) { _ in [] }
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertEqual(result.absencesOverruled, 1)
    }

    func testBallMissingJustUnderTheLimitKeepsTheStreak() {
        let observations = samples(2_100...5_000, step: 100, visible: true, ball: false) + samples(5_100...6_000, step: 100, visible: true)
        let result = assess(evidence(observations)) { _ in XCTFail("Under the limit needs no second look"); return [] }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testBallMissingForTheLimitEndsTheStreakWhenTheVideoAgrees() {
        // Counted from 0.3 s after the touch, while the ball is sure to be in frame.
        let observations = samples(2_100...5_400, step: 100, visible: true, ball: false) + samples(5_500...6_000, step: 100, visible: true)
        let result = assess(evidence(observations)) { window in
            self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: false)
        }
        XCTAssertEqual(result.decisions.map(\.kind), [.ballOutOfView])
        XCTAssertEqual(result.decisions[0].timeMS, 2_400)
        XCTAssertEqual(result.secondLooks, 1)
        XCTAssertEqual(result.absencesOverruled, 0)
    }

    func testGapsUnderTheLimitAreNeverChecked() {
        let result = assess(evidence(samples(1_000...4_000, visible: false, ball: false)), touches: [1, 2, 3, 3.9, 4]) { _ in
            XCTFail("Normal juggling costs no extra work"); return []
        }
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertEqual(result.secondLooks, 0)
    }

    func testTheMomentsAroundATouchNeverCountAsMissing() {
        // Nothing seen at all, but at 3.5 s from touch to touch only 2.9 s is really open.
        let live = samples(2_050...5_450, step: 100, visible: true, ball: false)
        let result = assess(evidence(live), touches: [2, 5.5]) { _ in XCTFail("Under the limit once the touches are set aside"); return [] }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    // MARK: A missing ball

    /// Everything a real streak can look like while the ball is briefly gone.
    func testHighKicksAndHiddenBallsKeepTheStreak() {
        // Out of frame for 2.78 s is a kick about 11 m high with the frame ending at 1.5 m.
        for (label, out) in [("high kick", 2_780), ("behind the legs, longest measured", 1_570), ("turned away", 2_500)] {
            let leaves = 2_300
            let observations = samples(2_100...leaves, step: 100, visible: true)
                + samples(leaves+100...leaves+out, step: 100, visible: true, ball: false)
                + samples(leaves+out+100...5_900, step: 100, visible: true)
            let result = assess(evidence(observations)) { _ in XCTFail("\(label) needs no second look"); return [] }
            XCTAssertTrue(result.decisions.isEmpty, label)
        }
    }

    func testTwoHighKicksInARowKeepTheStreakWhenTheBallIsSeenBetween() {
        let observations = samples(2_100...4_600, step: 100, visible: true, ball: false)
            + samples(4_700...5_400, step: 100, visible: true)
            + samples(5_500...8_000, step: 100, visible: true, ball: false)
        XCTAssertTrue(assess(evidence(observations), touches: [1, 2, 8.1, 9]).decisions.isEmpty)
    }

    func testBallSeenInTheSavedVideoOverrulesALiveMiss() {
        let live = samples(2_100...5_900, step: 100, visible: true, ball: false)
        let result = assess(evidence(live)) { window in
            self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: true)
        }
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertEqual(result.absencesOverruled, 1)
    }

    func testUnreadableVideoNeverEndsAStreakForAMissingBall() {
        let live = samples(2_100...5_900, step: 100, visible: true, ball: false)
        let result = assess(evidence(live)) { _ in [] }
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertEqual(result.absencesOverruled, 1)
    }

    func testPartlyReadableVideoNeverEndsAStreakForAMissingBall() {
        let live = samples(2_100...5_900, step: 100, visible: true, ball: false)
        let result = assess(evidence(live)) { window in
            Array(self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: false).prefix(4))
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testSparseFramesCannotProveAMissingBall() {
        // A hot phone falling behind: the player is seen, the ball is not, and
        // the frames are too far apart to say anything.
        let live = samples(2_100...5_900, step: 800, visible: true, ball: false)
        let result = assess(evidence(live)) { _ in XCTFail("Too little live evidence to look further"); return [] }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testAlreadySeparatedRunsDoNotCheckTheBall() {
        let live = samples(2_100...5_900, step: 100, visible: true, ball: false)
        let result = assess(evidence(live), boundaries: [3]) { _ in XCTFail("Already split by a hold/bounce"); return [] }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testMissingBallEndsTheStreakButKeepsEveryTouchInTheTotal() throws {
        let touches = [1.0, 2, 6, 7, 8]
        let live = samples(2_100...5_900, step: 100, visible: true, ball: false)
        let result = assess(evidence(live), touches: touches) { window in
            self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: false)
        }
        var review = TouchReviewEvidence()
        for cut in result.decisions { review.append(time: Double(cut.timeMS)/1000, kind: cut.kind) }
        let persisted = try XCTUnwrap(LeaderboardTouchReview.make(evidence: review, touchTimes: touches, duration: 10))
        let restored = try JSONDecoder().decode(LeaderboardTouchReview.self, from: JSONEncoder().encode(persisted))
        XCTAssertEqual(restored, persisted)
        let streak = RankedStreakProposal.suggest(touchTimes: touches, boundaries: restored.streakBoundaries, duration: 10)
        XCTAssertEqual(streak?.count, 3)
        XCTAssertEqual(touches.count, 5)
        XCTAssertNotNil(restored.visibilityNotice)
    }

    func testPlayerLeavingIsReportedAsThePlayerEvenWhenTheBallIsGoneToo() {
        let live = samples(2_100...5_900, step: 100, visible: false, ball: false)
        XCTAssertEqual(assess(evidence(live), recheck: emptyVideo).decisions.map(\.kind), [.playerOutOfView])
    }

    func testRollingBallInViewNeverCountsAsMissing() {
        // A second person or a ball resting in view: this rule stays out of it,
        // and the hold and floor checks decide.
        let live = samples(2_100...9_900, step: 100, visible: true, ball: true)
        XCTAssertTrue(assess(evidence(live), touches: [1, 2, 10, 11]).decisions.isEmpty)
    }

    // MARK: Stray detections

    /// The clip behind this rule: tiny false boxes in an empty frame made one
    /// video measure anywhere from 1.77 s to 3.5 s.
    func testALoneFalseBallDetectionDoesNotRestartTheClock() {
        let strays = [29_580, 30_280, 31_150]
        for kept in strays.indices.map({ Array(strays.prefix($0+1)) }) {
            let live = stride(from: 28_600, to: 32_000, by: 33).map { time in
                StreakVisibilityEvidence.Sample(timeMS: time, personVisible: true,
                    ballVisible: kept.contains { abs($0-time) <= 16 })
            }
            let result = assess(evidence(live), touches: [28, 32.1]) { window in
                self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: false)
            }
            XCTAssertEqual(result.decisions.map(\.kind), [.ballOutOfView], "\(kept)")
        }
    }

    func testALoneFalsePersonDetectionDoesNotRestartTheClock() {
        let source = evidence(samples(2_250...5_750, visible: false) + [.init(timeMS: 4_000, personVisible: true, ballVisible: true)])
        XCTAssertEqual(assess(source, recheck: emptyVideo).decisions.map(\.kind), [.playerOutOfView])
    }

    func testTwoSightingsCloseTogetherMeanItIsReallyThere() {
        for spacing in [33, 100, 250, 500, 600] {
            let live = samples(2_100...5_900, step: 100, visible: true, ball: false)
                + [.init(timeMS: 4_050, personVisible: true, ballVisible: true),
                   .init(timeMS: 4_050+spacing, personVisible: true, ballVisible: true)]
            let result = assess(evidence(live)) { _ in XCTFail("Seen at \(spacing) ms apart"); return [] }
            XCTAssertTrue(result.decisions.isEmpty, "\(spacing)")
        }
    }

    /// Found by the simulation: a high kick with one sighting beside each touch
    /// looked like 3.5 s of nothing, because both sightings were alone.
    func testOneSightingBesideATouchCountsBecauseTheTouchProvesTheBall() {
        let live = stride(from: 2_050, to: 5_500, by: 143).map { time in
            StreakVisibilityEvidence.Sample(timeMS: time, personVisible: true, ballVisible: time == 2_193 || time == 5_197)
        }
        let result = assess(evidence(live), touches: [2, 5.5]) { window in
            self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: false)
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testAFalseSightingAwayFromTheTouchesStillDoesNotCount() {
        let live = stride(from: 2_050, to: 7_000, by: 100).map { time in
            StreakVisibilityEvidence.Sample(timeMS: time, personVisible: true, ballVisible: time == 4_050)
        }
        let result = assess(evidence(live), touches: [2, 7]) { window in
            self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: false)
        }
        XCTAssertEqual(result.decisions.map(\.kind), [.ballOutOfView])
    }

    func testFlickeringDetectionStillCountsAsSeen() {
        // A ball the detector finds only now and then is still a ball.
        for every in [2, 3, 4, 5] {
            let live = stride(from: 2_100, to: 5_900, by: 100).enumerated().map { index, time in
                StreakVisibilityEvidence.Sample(timeMS: time, personVisible: true, ballVisible: index % every == 0)
            }
            let result = assess(evidence(live)) { _ in XCTFail("Seen every \(every) replies"); return [] }
            XCTAssertTrue(result.decisions.isEmpty, "\(every)")
        }
    }

    func testFlickeringPlayerDetectionStillCountsAsSeen() {
        for every in [2, 3, 4, 5] {
            let live = stride(from: 2_100, to: 5_900, by: 100).enumerated().map { index, time in
                StreakVisibilityEvidence.Sample(timeMS: time, personVisible: index % every == 0, ballVisible: true)
            }
            XCTAssertTrue(assess(evidence(live)).decisions.isEmpty, "\(every)")
        }
    }

    func testRepliesAtEveryPhoneSpeedGiveTheSameAnswer() {
        for hz in [7, 10, 15, 20, 30, 60, 120] {
            let step = 1_000/hz
            let leaves = stride(from: 2_100, to: 7_000, by: step).map {
                StreakVisibilityEvidence.Sample(timeMS: $0, personVisible: true, ballVisible: $0 > 6_000)
            }
            let ended = assess(evidence(leaves), touches: [2, 7]) { window in
                self.samples(window.startMS+250...window.endMS-1, step: 500, visible: true, ball: false)
            }
            XCTAssertEqual(ended.decisions.map(\.kind), [.ballOutOfView], "\(hz) Hz")

            let kept = stride(from: 2_100, to: 6_000, by: step).map {
                StreakVisibilityEvidence.Sample(timeMS: $0, personVisible: true, ballVisible: $0 > 4_500)
            }
            XCTAssertTrue(assess(evidence(kept), touches: [2, 6]).decisions.isEmpty, "\(hz) Hz")
        }
    }

    // MARK: Telling people

    func testTheBallStopIsNamedInEveryPlaceItIsShown() {
        XCTAssertTrue(ContactReviewReason.ballOutOfView.breaksStreak)
        XCTAssertTrue(ContactReviewReason.ballOutOfView.title.contains("Ball") || !AppLanguage.locale.identifier.hasPrefix("en"))
        XCTAssertFalse(ContactReviewReason.ballOutOfView.explanation.isEmpty)
        XCTAssertFalse(ContactReviewReason.ballOutOfView.stopReason.contains("hand"))
    }

    func testEveryRuleSentenceIsTranslated() throws {
        let sentences = [
            "If you or the ball are out of sight for at least 3 seconds, a new streak starts when touches resume. If part of a session cannot be checked, streaks on either side stay separate. Your total touches are kept.",
            "No player was visible for at least 3 seconds, so a new streak started. All touches stay in your total.",
            "No player was visible for at least 3 seconds, so touches before and after count as separate streaks. Your total touches are kept.",
            "The ball was out of sight for at least 3 seconds, so a new streak started. All touches stay in your total.",
            "The ball was out of sight for at least 3 seconds, so touches before and after count as separate streaks. Your total touches are kept.",
            "the player was out of view for at least 3 seconds",
            "the ball was out of sight for at least 3 seconds",
            "Ball out of view"]
        for language in ["de", "es", "fr", "pt-BR"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for sentence in sentences {
                let translated = bundle.localizedString(forKey: sentence, value: "MISSING", table: nil)
                XCTAssertNotEqual(translated, "MISSING", "\(language): \(sentence)")
                XCTAssertNotEqual(translated, sentence, "\(language): \(sentence)")
                if sentence.contains("3 seconds") { XCTAssertTrue(translated.contains("3"), "\(language): \(translated)") }
                XCTAssertFalse(translated.contains("2,5"), "\(language): \(translated)")
            }
        }
    }

    func testOldSavedSessionsKeepTheirReason() throws {
        let data = Data(#"{"version":1,"durationMS":9000,"complete":true,"moments":[{"kind":"playerOutOfView","timeMS":3000,"lastTimeMS":3000,"clipStartMS":2000,"clipEndMS":4200}]}"#.utf8)
        let review = try JSONDecoder().decode(LeaderboardTouchReview.self, from: data)
        XCTAssertEqual(review.moments.map(\.kind), [.playerOutOfView])
        XCTAssertNotNil(review.visibilityNotice)
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
        let result = assess(source, touches: [1, 2, 6, 7, 11, 12, 13], recheck: emptyVideo)
        XCTAssertEqual(result.decisions.count, 2)
        let score = RankedStreakProposal.suggest(touchTimes: [1, 2, 6, 7, 11, 12, 13],
            boundaries: result.decisions.map { Double($0.timeMS)/1000 }, duration: 15)
        XCTAssertEqual(score?.count, 3)
    }

    func testDuplicatesCannotSupplyIndependentAbsenceEvidence() {
        let source = evidence(Array(repeating: .init(timeMS: 2_250, personVisible: false, ballVisible: false), count: 40)
            + Array(repeating: .init(timeMS: 5_250, personVisible: false, ballVisible: false), count: 40))
        XCTAssertEqual(assess(source).decisions.map(\.kind), [.visibilityUnverified])
    }

    func testFreshVisibleObservationsResetAbsenceGrace() {
        let source = evidence(samples(2_250...5_750, visible: false)
            + [.init(timeMS: 3_900, personVisible: true, ballVisible: true), .init(timeMS: 4_100, personVisible: true, ballVisible: true)])
        XCTAssertTrue(assess(source).decisions.isEmpty)
    }

    func testInvalidTouchTimesAndNoStreakDoNotRequestRechecks() {
        let result = assess(evidence([]), touches: [.nan, .infinity, -1, 1, 1, 90_000]) { _ in
            XCTFail("No pair of valid contacts"); return []
        }
        XCTAssertTrue(result.decisions.isEmpty)
    }
}
