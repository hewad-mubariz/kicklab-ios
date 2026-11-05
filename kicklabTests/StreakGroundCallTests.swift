import XCTest
@testable import kicklab

/// The leaderboard follows the counter. One real session, recorded on 4 November
/// 2026, had 274 counted touches and a best streak of 23. Numbers only, no pixels.
final class StreakGroundCallTests: XCTestCase {
    private func resource(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "plist")))
    }

    /// Replays the real counter, as the app runs it, and returns the streak stops.
    private func replay(_ trace: CounterTrace) throws -> (counter: StreamingCounter, stops: [Double]) {
        let recorded = (trace.streakInterruptions ?? []).compactMap(\.ground)
        let times = Dictionary(trace.decisions.map { ($0.value.frameIndex, $0.value.timestampMs) }) { first, _ in first }
        let counter = try trace.replayedCounter(diagnoseContact: { decision, ball in
            .init(frameIndex: decision.frameIndex, time: Double(decision.timestampMs)/1000, rejection: decision.rejection,
                  handConfirmed: decision.handRejected == true, bodyFailure: nil, ball: ball)
        }, streakGroundEvidence: { frame in
            recorded.first { $0.contactMs == times[frame] }
        })
        return (counter, counter.reviewEvidence.observations.filter(\.kind.breaksStreak).map(\.time))
    }

    private func session() throws -> CounterTrace {
        try PropertyListDecoder().decode(CounterTraceArchive.self, from: resource("session-274-counter-v9")).trace
    }

    func testACountedContactCannotAlsoEndTheStreak() throws {
        let trace = try session()
        let (_, stops) = try replay(trace)
        // Six contacts were called the floor and counted one frame later.
        for touch in trace.touches {
            XCTAssertFalse(stops.contains { abs($0*1000-Double(touch.timestampMs)) <= 40 }, "Touch at \(touch.timestampMs)")
        }
    }

    func testAConfirmedFootCannotEndTheStreak() throws {
        let trace = try session()
        let (_, stops) = try replay(trace)
        let confirmed = trace.decisions.map(\.value).filter { $0.rejection == .groundBounce && $0.footConfirmed == true }
        XCTAssertEqual(confirmed.count, 12)
        for decision in confirmed {
            XCTAssertFalse(stops.contains(Double(decision.timestampMs)/1000), "Frame \(decision.frameIndex)")
        }
    }

    func testTheSessionKeepsEveryTouchAndItsBestStreakRises() throws {
        let trace = try session()
        let (counter, stops) = try replay(trace)
        // `replayedCounter` has already refused any change to a counter decision.
        XCTAssertEqual(counter.touches.count, 274)
        // 41 stops before. It was non-stop juggling, so none should be left.
        XCTAssertEqual(stops.count, 0)
        // The trace keeps device clock times; the app passes them from the recording's start.
        let start = Double(counter.touches[0].timestampMs)/1000
        let times = counter.touches.map { Double($0.timestampMs)/1000-start }
        let best = RankedStreakProposal.suggest(touchTimes: times, boundaries: stops.map { $0-start }, duration: times.last!+1)
        XCTAssertEqual(best?.count, 274, "It was 23")
    }

    func testRealFloorBouncesStillEndTheStreak() throws {
        let trace = try PropertyListDecoder().decode(CounterTrace.self, from: resource("sparse-floor-bounces-counter-v8"))
        let (_, stops) = try replay(trace)
        XCTAssertEqual(stops.count, 7)
    }

    private func call(_ ms: Int, fall: Double = 1, previous: Int?) -> StreakGroundCalls.Call {
        .init(frameIndex: ms/33, timestampMs: ms, time: Double(ms)/1000, fallBallHeights: fall, previousTouchMs: previous)
    }

    func testACallInUnbrokenJugglingIsOverruled() {
        var calls = StreakGroundCalls()
        calls.add(call(1_000, previous: 500))
        XCTAssertEqual(calls.touch(frameIndex: 45, timestampMs: 1_500).map(\.sameContact), [false])
    }

    func testABreakInTheRhythmLeavesTheCallStanding() {
        var before = StreakGroundCalls(), after = StreakGroundCalls()
        before.add(call(5_000, previous: 3_700))
        XCTAssertTrue(before.touch(frameIndex: 170, timestampMs: 5_500).isEmpty, "Long gap before the bounce")
        after.add(call(1_000, previous: 500))
        XCTAssertTrue(after.touch(frameIndex: 90, timestampMs: 3_000).isEmpty, "Long gap after the bounce")
    }

    func testAFallFromARealHeightLeavesTheCallStanding() {
        var calls = StreakGroundCalls()
        calls.add(call(1_000, fall: 2.5, previous: 500))
        XCTAssertTrue(calls.touch(frameIndex: 45, timestampMs: 1_500).isEmpty)
    }

    func testAnUnknownFallLeavesTheCallStanding() {
        var calls = StreakGroundCalls()
        calls.add(.init(frameIndex: 30, timestampMs: 1_000, time: 1, fallBallHeights: nil, previousTouchMs: 500))
        XCTAssertTrue(calls.touch(frameIndex: 45, timestampMs: 1_500).isEmpty)
    }

    func testKickBounceKickBounceStillEndsTheStreak() {
        var calls = StreakGroundCalls()
        var overruled: [Int] = []
        for step in 0..<6 {
            let touch = 1_000+step*1_000
            calls.add(call(touch-500, previous: touch-1_000))
            overruled.append(calls.touch(frameIndex: touch/33, timestampMs: touch).count)
        }
        XCTAssertEqual(overruled, [1, 1, 0, 0, 0, 0], "Two can be low taps; three in a row is bouncing")
    }

    func testTheNextFrameIsAlwaysTheSameContact() {
        var calls = StreakGroundCalls()
        calls.add(call(5_000, fall: 9, previous: 100))
        XCTAssertEqual(calls.touch(frameIndex: 5_000/33+1, timestampMs: 5_033).map(\.sameContact), [true])
    }

    func testOnlyAFloorCallCanBeOverruled() {
        var evidence = TouchReviewEvidence()
        evidence.append(time: 1, kind: .heldBall)
        evidence.overrule(groundContactAt: 1, sameContact: true)
        XCTAssertEqual(evidence.observations.map(\.kind), [.heldBall])
        evidence.append(time: 2, kind: .groundContact)
        evidence.overrule(groundContactAt: 2, sameContact: false)
        XCTAssertEqual(evidence.observations.map(\.kind), [.heldBall, .lowContactUncertain])
        evidence.append(time: 3, kind: .groundContact)
        evidence.overrule(groundContactAt: 3, sameContact: true)
        XCTAssertEqual(evidence.observations.map(\.kind), [.heldBall, .lowContactUncertain])
    }
}
