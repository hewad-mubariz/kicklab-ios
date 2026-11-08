import XCTest
@testable import kicklab

/// Thousands of made-up sessions with repeatable randomness. A failure names
/// the seed, so that exact session can be replayed.
final class StreakAbsenceSimulationTests: XCTestCase {
    private let sessions = 1_500

    private func run(_ scenario: StreakScenario, check: (StreakVisibilityEvidence.Assessment, SimulatedGap, UInt64) -> Void) {
        for index in 0..<sessions {
            let seed = UInt64(index)*7_919+UInt64(StreakScenario.allCases.firstIndex(of: scenario)!)
            var random = SeededGenerator(seed: seed)
            let gap = scenario.gap(using: &random)
            check(gap.assess(using: &random), gap, seed)
        }
    }

    private func assertNeverEnds(_ scenario: StreakScenario, file: StaticString = #filePath, line: UInt = #line) {
        run(scenario) { result, gap, seed in
            XCTAssertTrue(result.decisions.isEmpty,
                "\(scenario) ended a valid streak: seed \(seed), \(gap.lengthMS) ms, \(gap.detector), \(result.decisions.map(\.kind))",
                file: file, line: line)
        }
    }

    func testTouchesMissedByTheCounterNeverEndTheStreak() { assertNeverEnds(.touchesMissedByTheCounter) }
    func testHighKicksNeverEndTheStreak() { assertNeverEnds(.highKick) }
    func testTwoHighKicksInARowNeverEndTheStreak() { assertNeverEnds(.twoHighKicksInARow) }
    func testABallHiddenByTheBodyNeverEndsTheStreak() { assertNeverEnds(.ballHiddenByTheBody) }
    func testAPlayerAtTheEdgeOfFrameNeverEndsTheStreak() { assertNeverEnds(.playerAtTheEdgeOfFrame) }
    func testAPhoneFallingBehindNeverEndsTheStreak() { assertNeverEnds(.phoneFallingBehind) }
    func testASavedVideoThatShowsTheBallAlwaysSavesTheStreak() { assertNeverEnds(.liveDetectorBlind) }
    func testAnUnreadableSavedVideoNeverEndsTheStreak() { assertNeverEnds(.savedVideoUnreadable) }

    /// Real stops must come out the same way nearly every time, whatever the
    /// phone and however many false boxes appear. That is the stability asked for.
    private func assertAlmostAlwaysEnds(_ scenario: StreakScenario, atLeast share: Double, file: StaticString = #filePath, line: UInt = #line) {
        var ended = 0
        run(scenario) { result, gap, seed in
            let kinds = Set(result.decisions.map(\.kind))
            XCTAssertTrue(kinds.isSubset(of: scenario.expectedStops),
                "\(scenario) gave the wrong reason: seed \(seed), \(gap.detector), \(kinds)", file: file, line: line)
            if !kinds.isEmpty { ended += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(ended)/Double(sessions), share, "\(scenario) ended \(ended) of \(sessions)", file: file, line: line)
    }

    // False boxes near the limit can hide a short exit, so the ball gets a lower bar.
    func testABallThatIsReallyGoneEndsTheStreak() { assertAlmostAlwaysEnds(.ballGone, atLeast: 0.9) }
    func testAPlayerAndBallThatAreReallyGoneEndTheStreak() { assertAlmostAlwaysEnds(.playerAndBallGone, atLeast: 0.99) }
    func testAPlayerWhoIsReallyGoneEndsTheStreak() { assertAlmostAlwaysEnds(.playerGoneBallInView, atLeast: 0.99) }

    func testTheSameSessionAlwaysGivesTheSameAnswer() {
        for scenario in StreakScenario.allCases {
            for seed in UInt64(0)..<50 {
                var first = SeededGenerator(seed: seed), second = SeededGenerator(seed: seed)
                let a = scenario.gap(using: &first), b = scenario.gap(using: &second)
                XCTAssertEqual(a.assess(using: &first).decisions, b.assess(using: &second).decisions, "\(scenario) \(seed)")
            }
        }
    }

    func testHighestKickThatFitsStaysUnderTheLimit() {
        XCTAssertLessThan(StreakScenario.timeOutOfFrameMS(height: 11, frameTop: 1.5), StreakVisibilityEvidence.graceMS)
    }

    /// Long ordinary juggling costs nothing and can never reach the rule.
    func testHalfAnHourOfJugglingNeedsNoCheckAtAll() {
        var random = SeededGenerator(seed: 11)
        var touches = [10.0], evidence = StreakVisibilityEvidence()
        while touches.last! < 1_800 { touches.append(touches.last!+Double.random(in: 0.3...1.2, using: &random)) }
        for time in stride(from: 10_000, to: 1_800_000, by: 100) {
            evidence.record(timeMS: time, personVisible: true, ballVisible: Double.random(in: 0..<1, using: &random) < 0.9)
        }
        let result = evidence.assess(touchTimes: touches, existingBoundaries: []) { _ in
            XCTFail("Nothing to recheck"); return []
        }
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertEqual(result.secondLooks, 0)
        XCTAssertEqual(result.recheckedFrames, 0)
        let streak = RankedStreakProposal.suggest(touchTimes: touches, boundaries: [], duration: 1_810)
        XCTAssertEqual(streak?.count, touches.count)
    }
}
