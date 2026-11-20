#if DEBUG
import AVFoundation
import XCTest
@testable import kicklab

final class WallArcadeRulesTests: XCTestCase {
    private let footprint = WallContactFootprint(xAxis: CGPoint(x: 0.05, y: 0), yAxis: CGPoint(x: 0, y: 0.05))

    func testClockMapsDelayedContactsAcrossPausesWithoutAdvancingTheScene() throws {
        var clock = WallGameClock()
        clock.start(at: 100); clock.pause(at: 105)
        XCTAssertEqual(clock.time(at: 140), 5)
        clock.resume(at: 150); clock.pause(at: 155)
        XCTAssertEqual(clock.time(at: 104), 4)
        XCTAssertEqual(clock.time(at: 130), 5)
        XCTAssertEqual(clock.time(at: 153), 8)
        XCTAssertEqual(clock.time(at: 200), 10)
        XCTAssertNil(clock.time(at: 99)); XCTAssertNil(clock.time(at: .nan))
        clock.resume(at: 154) // An old callback cannot restart time.
        XCTAssertFalse(clock.running)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: clock.json))
    }

    func testMemorySeedsAreReplayableAndNoPadRepeatsImmediately() {
        for seed in 1...100 {
            let a = WallMemoryStrike(seed: UInt64(seed)), b = WallMemoryStrike(seed: UInt64(seed))
            XCTAssertEqual(a.pattern, b.pattern)
            XCTAssertEqual(a.pattern.count, 6)
            XCTAssertTrue(a.pattern.allSatisfy { (1...4).contains($0) })
            XCTAssertFalse(zip(a.pattern, a.pattern.dropFirst()).contains { $0 == $1 })
        }
        XCTAssertNotEqual(WallMemoryStrike(seed: 1).pattern, WallMemoryStrike(seed: 2).pattern)
    }

    func testMemoryFourSymbolLayoutLeavesGapsAndKeepsIndependentScores() throws {
        let layout = WallTargetLayout.memoryPads
        XCTAssertEqual(layout.ids, [1, 2, 3, 4])
        for target in layout.targets {
            XCTAssertEqual(layout.target(u: target.frame.midX, v: target.frame.midY), target.id)
        }
        XCTAssertNil(layout.target(u: 1.5, v: 0.7)) // Between star and moon.
        XCTAssertNil(layout.target(u: 0.8, v: 1.1)) // Between star and sun.
        XCTAssertNil(layout.target(u: 0.2, v: 0.2)) // Scenery isn't a target.
        XCTAssertNotEqual(WallGame.memoryStrike.bestScoreKey, "wallTargets.memory-strike-v1.bestScore")
    }

    func testMemoryDemoNeverScoresEvenWhenTheCallbackArrivesDuringRecall() {
        var state = WallMemoryStrike(seed: 17)
        let end = state.watchEnd
        XCTAssertNotNil(state.highlighted(at: 1.4))
        XCTAssertFalse(state.hit(target: state.sequence[0], point: .zero, contact: 1.4, now: 1.6))
        XCTAssertFalse(state.hit(target: state.sequence[0], point: .zero, contact: end - 0.1, now: end + 0.3))
        XCTAssertEqual(state.score, 0); XCTAssertEqual(state.lives, 3)
        XCTAssertNil(state.highlighted(at: end + 0.3))
    }

    func testMemoryCompletesFiveGrowingSequencesAndStops() {
        var state = WallMemoryStrike(seed: 5)
        var now = 0.0
        for round in 1...5 {
            if state.phase == .interlude { now += 2; state.advance(at: now) }
            now = state.watchEnd; state.advance(at: now)
            XCTAssertEqual(state.sequence.count, round + 1)
            for target in state.sequence {
                now += 1
                XCTAssertTrue(state.hit(target: target, point: .zero, contact: now - 0.2, now: now))
            }
        }
        XCTAssertEqual(state.completedRounds, 5); XCTAssertEqual(state.phase, .finished); XCTAssertTrue(state.won)
        XCTAssertEqual(state.score, 3800)
        let finished = state
        state.advance(at: now + 1000)
        XCTAssertFalse(state.hit(target: 1, point: .zero, contact: now + 2, now: now + 2.3))
        XCTAssertEqual(state, finished)
    }

    func testWrongMemoryPadCostsOneLifeAndReplaysTheSamePattern() {
        var state = WallMemoryStrike(seed: 17)
        let pattern = state.pattern
        for attempt in 0..<3 {
            let end = state.watchEnd; state.advance(at: end)
            let wrong = state.sequence[0] % 4 + 1
            XCTAssertFalse(state.hit(target: wrong, point: .zero, contact: end + 1, now: end + 1.2))
            XCTAssertEqual(state.lives, 2 - attempt); XCTAssertEqual(state.cursor, 0)
            XCTAssertEqual(state.pattern, pattern); XCTAssertEqual(state.round, 1)
            state.advance(at: end + 3)
        }
        XCTAssertEqual(state.phase, .finished); XCTAssertFalse(state.won)
    }

    func testFailedMemoryPrefixCannotFarmPointsByRepeatingTheSamePad() {
        var state = WallMemoryStrike(seed: 17)
        for attempt in 0..<2 {
            let end = state.watchEnd; state.advance(at: end)
            XCTAssertTrue(state.hit(target: state.sequence[0], point: .zero, contact: end + 1, now: end + 1.2))
            XCTAssertEqual(state.score, 100)
            let wrong = state.sequence[1] % 4 + 1
            XCTAssertFalse(state.hit(target: wrong, point: .zero, contact: end + 2, now: end + 2.2))
            XCTAssertEqual(state.score, 0); XCTAssertEqual(state.lives, 2 - attempt)
            state.advance(at: end + 4)
        }
    }

    func testMemoryDeadlineAllowsConfirmationGraceButNoLatePhysicalContact() {
        var state = WallMemoryStrike(seed: 17)
        state.advance(at: state.watchEnd)
        let end = state.deadline
        var late = state
        XCTAssertTrue(state.hit(target: state.sequence[0], point: .zero, contact: end - 0.1, now: end + 0.4))
        XCTAssertFalse(late.hit(target: late.sequence[0], point: .zero, contact: end + 0.1, now: end + 0.4))
        late.advance(at: end + 0.81)
        XCTAssertEqual(late.lives, 2); XCTAssertEqual(late.phase, .interlude)
    }

    func testMeteorHitUsesContactPositionInsteadOfCallbackPosition() throws {
        var state = WallMeteorDefence(seed: 17), wrongTime = state
        let rock = state.meteors[0], contact = rock.spawn + 5
        let centre = rock.position(at: contact)
        let edge = CGPoint(x: centre.x, y: centre.y - 0.245)
        XCTAssertFalse(rock.overlaps(edge, footprint: footprint, at: contact + 0.6))
        XCTAssertEqual(state.hit(point: edge, footprint: footprint, contact: contact, now: contact + 0.6), rock.id)
        XCTAssertNil(wrongTime.hit(point: edge, footprint: footprint, contact: contact + 0.6, now: contact + 0.6))
        XCTAssertEqual(state.destroyed, 1); XCTAssertEqual(state.score, 150)
    }

    func testMeteorCollisionIsCircularAndNeverIncludesTheFlameTail() {
        let rock = WallMeteorDefence(seed: 2).meteors[0], t = rock.spawn + 3
        let p = rock.position(at: t)
        XCTAssertFalse(rock.overlaps(CGPoint(x: p.x + 0.24, y: p.y + 0.24), footprint: footprint, at: t))
        XCTAssertFalse(rock.overlaps(CGPoint(x: p.x, y: p.y - 0.50), footprint: footprint, at: t))
        XCTAssertTrue(rock.overlaps(CGPoint(x: p.x + 0.24, y: p.y), footprint: footprint, at: t))
    }

    func testMeteorCannotBeHitBeforeSpawnAfterArrivalOrTwice() {
        var state = WallMeteorDefence(seed: 5)
        let rock = state.meteors[0], t = rock.spawn + 2
        XCTAssertNil(state.hit(point: rock.position(at: rock.spawn), footprint: footprint,
                               contact: rock.spawn - 0.01, now: rock.spawn + 0.1))
        XCTAssertEqual(state.hit(point: rock.position(at: t), footprint: footprint, contact: t, now: t + 0.2), rock.id)
        XCTAssertNil(state.hit(point: rock.position(at: t), footprint: footprint, contact: t, now: t + 0.3))
        var late = WallMeteorDefence(seed: 5)
        XCTAssertNil(late.hit(point: rock.position(at: rock.arrival), footprint: footprint,
                             contact: rock.arrival + 0.01, now: rock.arrival + 0.4))
        XCTAssertEqual(late.shields, 3) // Await pending confirmations before applying city damage.
        late.advance(at: rock.arrival + 0.81); XCTAssertEqual(late.shields, 2)
        late.advance(at: rock.arrival + 0.9); XCTAssertEqual(late.shields, 2)
    }

    func testMeteorJustInTimeHitCanArriveDuringGraceAndInvalidFootprintsCannotScore() {
        var state = WallMeteorDefence(seed: 5)
        let rock = state.meteors[0], t = rock.arrival - 0.05
        let invalid = WallContactFootprint(xAxis: .zero, yAxis: .zero)
        XCTAssertNil(state.hit(point: rock.position(at: t), footprint: invalid, contact: t, now: t + 0.5))
        XCTAssertEqual(state.hit(point: rock.position(at: t), footprint: footprint, contact: t, now: t + 0.5), rock.id)
        XCTAssertEqual(state.shields, 3)
    }

    func testMeteorThreeWavesWinAndUnansweredMeteorsLoseWithoutAnyShot() {
        var state = WallMeteorDefence(seed: 7)
        for wave in 1...3 {
            XCTAssertEqual(state.wave, wave)
            for rock in state.meteors {
                let t = rock.spawn + 2
                XCTAssertEqual(state.hit(point: rock.position(at: t), footprint: footprint, contact: t, now: t + 0.2), rock.id)
            }
            if wave < 3 { state.advance(at: state.phaseStart + 2.6) }
        }
        XCTAssertTrue(state.won); XCTAssertEqual(state.phase, .finished)
        XCTAssertEqual(state.destroyed, 12); XCTAssertEqual(state.score, 4350)
        XCTAssertEqual(state.resolved.count, 12)
        var lost = WallMeteorDefence(seed: 7)
        lost.advance(at: 100)
        XCTAssertFalse(lost.won); XCTAssertEqual(lost.shields, 0); XCTAssertEqual(lost.phase, .finished)
        let count = lost.events.count
        lost.advance(at: 1000); XCTAssertEqual(lost.events.count, count)
    }

    func testArcadeSoundsAreShortDecodableMonoPCM() throws {
        for cue in WallArcadeCue.allCases {
            let data = WallArcadeSound.data(for: cue)
            let player = try AVAudioPlayer(data: data)
            XCTAssertEqual(player.numberOfChannels, 1)
            XCTAssertGreaterThan(player.duration, 0.15); XCTAssertLessThan(player.duration, 0.8)
            let samples = stride(from: 44, to: data.count, by: 2).map { offset -> Double in
                Double(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)) / 32768
            }
            XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.2)
            XCTAssertLessThan(samples.map(abs).max() ?? 1, 0.95)
            XCTAssertLessThan(abs(samples.last ?? 1), 0.001)
        }
    }
}

@MainActor
final class WallArcadeModelTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100), host = 1000.0
    private let corners = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
        CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)]
    private func model(_ game: WallGame) -> WallTargetsModel {
        let m = WallTargetsModel(defaults: UserDefaults(suiteName: "ArcadeTests.\(UUID())")!)
        m.showGameIntro(); XCTAssertTrue(m.selectGame(game))
        XCTAssertTrue(m.beginGameSetup()); XCTAssertTrue(m.setCorners(corners)); m.validateMappingForTest()
        XCTAssertTrue(m.finishReference([0.04]))
        XCTAssertTrue(m.startPlay(at: start, hostTime: host, seed: 17))
        return m
    }
    private func impact(_ point: CGPoint, at time: Double) -> WallImpactDetector.Impact {
        .init(t: host + time, x: 500, y: 300, d: 44, turn: 90, u: point.x, v: point.y,
              box: nil, footprint: .preview)
    }
    func testMemoryIgnoresDemoAndRequiresFreshCorrectContacts() throws {
        let m = model(.memoryStrike)
        XCTAssertFalse(m.needsGameplayInference)
        let id = try XCTUnwrap(m.memory).sequence[0], frame = try XCTUnwrap(m.game.layout.target(id)).frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertFalse(m.accept(impact(point, at: 1.5), hostTime: host + 1.7) { _ in XCTFail() })
        m.tickArcade(at: start.addingTimeInterval(5), hostTime: host + 5)
        XCTAssertTrue(m.needsGameplayInference)
        let hit = impact(point, at: 5)
        var sounds = 0
        XCTAssertTrue(m.accept(hit, at: start.addingTimeInterval(5.2), hostTime: host + 5.2) { _ in sounds += 1 })
        XCTAssertFalse(m.accept(hit, hostTime: host + 5.3) { _ in XCTFail() })
        XCTAssertEqual(sounds, 1); XCTAssertEqual(m.hits.count, 1); XCTAssertEqual(m.memory?.cursor, 1)
    }
    func testMemoryErrorsHaveFeedbackButNeverAppearAsSuccessfulHits() throws {
        let m = model(.memoryStrike), correct = try XCTUnwrap(m.memory).sequence[0]
        m.tickArcade(hostTime: host + 5)
        let frame = try XCTUnwrap(m.game.layout.target(correct % 4 + 1)).frame
        XCTAssertFalse(m.accept(impact(CGPoint(x: frame.midX, y: frame.midY), at: 5),
            hostTime: host + 5.3) { _ in XCTFail() })
        XCTAssertTrue(m.hits.isEmpty); XCTAssertEqual(m.memory?.lives, 2)
        XCTAssertFalse(m.needsGameplayInference)
        XCTAssertTrue(m.arcadeEvents.contains { $0.cue == .memoryMiss })
    }
    func testOtherGamesKeepInputEnabledThroughAlignmentOcclusion() {
        for game in WallGame.allCases where game != .memoryStrike {
            let m = model(game)
            XCTAssertTrue(m.needsGameplayInference, game.rawValue)
            m.applyAlignment(.init(status: .obscured, corners: corners, revision: 1), hostTime: host + 5)
            XCTAssertTrue(m.needsGameplayInference, game.rawValue)
        }
    }
    func testMemoryCompletesThroughTheCameraContactEntryPointAndEndsTheRound() throws {
        let m = model(.memoryStrike)
        for round in 1...5 {
            if m.memory?.phase == .interlude {
                let t = try XCTUnwrap(m.memory).phaseStart + 1.7
                m.tickArcade(at: start.addingTimeInterval(t), hostTime: host + t)
            }
            let ready = try XCTUnwrap(m.memory).watchEnd + 0.01
            m.tickArcade(at: start.addingTimeInterval(ready), hostTime: host + ready)
            let state = try XCTUnwrap(m.memory)
            XCTAssertEqual(state.phase, .recalling); XCTAssertEqual(state.round, round)
            for (index, pad) in state.sequence.enumerated() {
                let t = state.phaseStart + Double(index + 1) * 2
                let frame = try XCTUnwrap(m.game.layout.target(pad)).frame
                XCTAssertTrue(m.accept(impact(CGPoint(x: frame.midX, y: frame.midY), at: t),
                    at: start.addingTimeInterval(t + 0.2), hostTime: host + t + 0.2) { _ in })
            }
        }
        XCTAssertEqual(m.arcadeWon, true); XCTAssertTrue(m.sessionEnded)
        XCTAssertEqual(m.gameScreen, .results); XCTAssertEqual(m.hits.count, 20)
        XCTAssertEqual(m.bestArcadeScore, 3800); XCTAssertEqual(m.memory?.lives, 3)
    }
    func testMeteorPauseFreezesAnimationAndDeadlinesAndKeepsOldContactMapping() throws {
        let m = model(.meteorDefence)
        m.applyAlignment(.init(status: .obscured, corners: corners, revision: 1),
                         at: start.addingTimeInterval(5), hostTime: host + 5)
        m.tickArcade(at: start.addingTimeInterval(60), hostTime: host + 60)
        XCTAssertEqual(m.arcadeTime(at: host + 60), 5); XCTAssertEqual(m.meteors?.shields, 3)
        m.applyAlignment(.init(status: .ready, corners: corners, revision: 1),
                         at: start.addingTimeInterval(60), hostTime: host + 60)
        XCTAssertEqual(m.arcadeTime(at: host + 61), 6)
        XCTAssertEqual(try XCTUnwrap(m.arcadeClock.time(at: host + 4.8)), 4.8, accuracy: 0.001)
        XCTAssertEqual(m.elapsed(at: start.addingTimeInterval(61)), 6, accuracy: 0.001)
    }
    func testMeteorLossAutomaticallyEndsRoundWithoutWaitingForHit() {
        let m = model(.meteorDefence)
        m.recordingState = .recording
        let cues = m.tickArcade(at: start.addingTimeInterval(40), hostTime: host + 40)
        XCTAssertEqual(cues.last, .defeat); XCTAssertEqual(m.arcadeWon, false)
        XCTAssertTrue(m.sessionEnded); XCTAssertFalse(m.isPlaying); XCTAssertEqual(m.gameScreen, .results)
        XCTAssertFalse(m.canStartGame) // The play view must finalize the recording before replay.
        XCTAssertNil(m.clearedAt)
        m.recordingState = .saved; XCTAssertTrue(m.canStartGame)
    }
    func testMeteorCompletesRecordsReplayMetadataAndKeepsIndependentHighScore() throws {
        let m = model(.meteorDefence)
        for wave in 1...3 {
            for rock in try XCTUnwrap(m.meteors).meteors {
                let t = rock.spawn + 2
                XCTAssertTrue(m.accept(impact(rock.position(at: t), at: t),
                    at: start.addingTimeInterval(t + 0.2), hostTime: host + t + 0.2) { _ in })
            }
            if wave < 3 {
                let t = try XCTUnwrap(m.meteors).phaseStart + 2.6
                m.tickArcade(at: start.addingTimeInterval(t), hostTime: host + t)
            }
        }
        XCTAssertTrue(m.sessionEnded); XCTAssertEqual(m.arcadeWon, true)
        XCTAssertEqual(m.hits.count, 12); XCTAssertEqual(m.bestArcadeScore, 4350)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: m.gameMetadata))
        XCTAssertNotNil(m.gameMetadata["arcadeClock"]); XCTAssertNotNil(m.gameMetadata["arcadeEvents"])
        m.showGameIntro(); XCTAssertTrue(m.selectGame(.memoryStrike))
        XCTAssertEqual(m.bestArcadeScore, 0); XCTAssertTrue(m.arcadeEvents.isEmpty)
        XCTAssertTrue(m.selectGame(.meteorDefence)); XCTAssertEqual(m.bestArcadeScore, 4350)
    }
    func testArcadeRejectsUncertainFutureStaleAndMisalignedContacts() throws {
        let m = model(.meteorDefence), rock = try XCTUnwrap(m.meteors).meteors[0]
        let point = rock.position(at: 5)
        var uncertain = impact(point, at: 5); uncertain.borderline = true
        XCTAssertFalse(m.accept(uncertain, hostTime: host + 5.2) { _ in XCTFail() })
        XCTAssertFalse(m.accept(impact(point, at: 6), hostTime: host + 5.2) { _ in XCTFail() })
        XCTAssertFalse(m.accept(impact(point, at: 3), hostTime: host + 5.2) { _ in XCTFail() })
        m.applyAlignment(.init(status: .shifted, corners: corners, revision: 2), hostTime: host + 5)
        XCTAssertFalse(m.accept(impact(point, at: 5), hostTime: host + 5.2) { _ in XCTFail() })
        XCTAssertTrue(m.hits.isEmpty); XCTAssertEqual(m.arcadeScore, 0)
    }
}
#endif
