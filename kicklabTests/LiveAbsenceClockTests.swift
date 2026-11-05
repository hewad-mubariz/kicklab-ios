import XCTest
@testable import kicklab

/// The recording screen's warning. It may only warn, so what matters is that it
/// stays quiet in valid juggling and always shows before the rule ends a streak.
final class LiveAbsenceClockTests: XCTestCase {
    private func feed(_ clock: inout LiveAbsenceClock, from start: Int, to end: Int, every step: Int = 100,
                      person: Bool = true, ball: Bool = true) {
        for time in stride(from: start, through: end, by: step) {
            clock.record(timeMS: time, personVisible: person, ballVisible: ball)
        }
    }

    func testSaysNothingBeforeTheFirstTouch() {
        // Pressing record and walking to your spot is not a lost streak.
        var clock = LiveAbsenceClock()
        feed(&clock, from: 0, to: 8_000, person: false, ball: false)
        XCTAssertNil(clock.warning(at: 8_000))
    }

    func testCountsDownThenSaysTheStreakHasEnded() {
        var clock = LiveAbsenceClock()
        feed(&clock, from: 0, to: 1_000)
        clock.counted(1)
        feed(&clock, from: 1_100, to: 2_500, ball: false)
        XCTAssertNil(clock.warning(at: 2_500), "A moment out of sight is normal juggling")
        feed(&clock, from: 2_600, to: 2_600, ball: false)
        XCTAssertEqual(clock.warning(at: 2_600), .init(subject: .ball, secondsLeft: 2))
        feed(&clock, from: 2_700, to: 3_100, ball: false)
        XCTAssertEqual(clock.warning(at: 3_100), .init(subject: .ball, secondsLeft: 1))
        feed(&clock, from: 3_200, to: 4_100, ball: false)
        XCTAssertEqual(clock.warning(at: 4_100), .init(subject: .ball, secondsLeft: 0))
        feed(&clock, from: 4_200, to: 9_000, ball: false)
        XCTAssertEqual(clock.warning(at: 9_000), .init(subject: .ball, secondsLeft: 0), "It stays until the ball is back")
    }

    func testACountedTouchClearsTheWarning() {
        var clock = LiveAbsenceClock()
        clock.counted(1)
        feed(&clock, from: 0, to: 2_500, ball: false)
        XCTAssertNotNil(clock.warning(at: 2_500))
        clock.counted(2)
        XCTAssertNil(clock.warning(at: 2_500))
    }

    func testTheSameTouchTotalDoesNotClearIt() {
        var clock = LiveAbsenceClock()
        clock.counted(3)
        feed(&clock, from: 0, to: 2_500, ball: false)
        clock.counted(3)
        XCTAssertNotNil(clock.warning(at: 2_500))
    }

    func testOneFalseDetectionDoesNotClearItButTwoCloseSightingsDo() {
        var clock = LiveAbsenceClock()
        clock.counted(1)
        feed(&clock, from: 0, to: 2_000, ball: false)
        feed(&clock, from: 2_100, to: 2_100, ball: true)
        feed(&clock, from: 2_200, to: 2_800, ball: false)
        XCTAssertNotNil(clock.warning(at: 2_800), "A lone box is not the ball coming back")
        feed(&clock, from: 2_900, to: 3_000, ball: true)
        XCTAssertNil(clock.warning(at: 3_000))
    }

    func testAPhoneFallingBehindIsNotAnAbsence() {
        var clock = LiveAbsenceClock()
        clock.counted(1)
        feed(&clock, from: 0, to: 2_000, ball: false)
        XCTAssertNil(clock.warning(at: 2_700), "No replies for 700 ms proves nothing")
        feed(&clock, from: 2_700, to: 2_800, ball: false)
        XCTAssertNil(clock.warning(at: 2_800), "The clock starts over after a gap, as the rule does")
    }

    func testAMissingPlayerComesBeforeAMissingBall() {
        var clock = LiveAbsenceClock()
        clock.counted(1)
        feed(&clock, from: 0, to: 2_000, person: false, ball: false)
        XCTAssertEqual(clock.warning(at: 2_000)?.subject, .player)
    }

    func testTheSlowestRepliesTheRuleAcceptsStillCountDown() {
        var clock = LiveAbsenceClock()
        clock.counted(1)
        feed(&clock, from: 0, to: 2_400, every: 600, ball: false)
        XCTAssertEqual(clock.warning(at: 2_400)?.secondsLeft, 1)
        feed(&clock, from: 3_000, to: 3_000, ball: false)
        XCTAssertEqual(clock.warning(at: 3_000)?.secondsLeft, 0)
    }

    private struct Case: Decodable {
        let expect: String, before: Int, after: Int, samples: String
        var timeline: [StreakVisibilityEvidence.Sample] {
            var time = before
            return samples.split(separator: " ").map { entry in
                let parts = entry.split(separator: ":").map { Int($0)! }
                time += parts[0]
                return .init(timeMS: time, personVisible: parts[1] & 2 != 0, ballVisible: parts[1] & 1 != 0)
            }
        }
    }
    private struct File: Decodable { let cases: [Case] }

    func testRealRecordingsWarnBeforeEveryStopAndNotInValidJuggling() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "streak-absence-cases", withExtension: "json"))
        let cases = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
        var stops = 0, valid = 0, warnedInValid = 0
        for item in cases {
            var clock = LiveAbsenceClock()
            clock.counted(1)
            var warned = false, ended = false
            for sample in item.timeline {
                clock.record(timeMS: sample.timeMS, personVisible: sample.personVisible, ballVisible: sample.ballVisible)
                guard let warning = clock.warning(at: sample.timeMS) else { continue }
                warned = true
                ended = ended || warning.secondsLeft == 0
            }
            if item.expect == "keep" {
                valid += 1
                XCTAssertFalse(ended, "Said ended in valid juggling at \(item.before)")
                if warned { warnedInValid += 1 }
            } else {
                stops += 1
                XCTAssertTrue(ended, "No warning before the stop at \(item.before)")
            }
        }
        XCTAssertEqual(stops, 12); XCTAssertEqual(valid, 123)
        // Hand-picked hard stretches with touches removed: one real moment of 1.6 s, in three cases.
        XCTAssertLessThanOrEqual(warnedInValid, 3)
    }

    func testTheWordsAreTranslated() throws {
        for language in ["de", "es", "fr", "pt-BR"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for words in ["Streak is about to end", "New streak when you continue", "Ball out of view", "Player out of view"] {
                let translated = bundle.localizedString(forKey: words, value: "MISSING", table: nil)
                XCTAssertNotEqual(translated, "MISSING", "\(language): \(words)")
                XCTAssertNotEqual(translated, words, "\(language): \(words)")
            }
        }
    }
}
