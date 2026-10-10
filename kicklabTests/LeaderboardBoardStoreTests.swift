import XCTest
@testable import kicklab

@MainActor
final class LeaderboardBoardStoreTests: XCTestCase {
    private func board(_ score: Int) -> LeaderboardBoard {
        .init(entries: [.init(rank: 1, name: "Alex", touches: score, isYou: true)], around: [])
    }

    func testTabsFetchOnceAndRefreshReplacesOnlySelectedTab() async {
        let store = LeaderboardBoardStore()
        var calls: [LeaderboardPeriod: Int] = [:]
        for period in [LeaderboardPeriod.week, .allTime, .week, .allTime] {
            await store.load(period, viewer: "player") {
                calls[period, default: 0] += 1
                return self.board(period == .week ? 74 : 96)
            }
        }
        XCTAssertEqual(calls[.week], 1)
        XCTAssertEqual(calls[.allTime], 1)
        await store.load(.week, viewer: "player", refresh: true) {
            calls[.week, default: 0] += 1
            return self.board(80)
        }
        XCTAssertEqual(calls[.week], 2)
        XCTAssertEqual(calls[.allTime], 1)
        XCTAssertEqual(store.state(for: .week, viewer: "player").board?.entries.first?.touches, 80)
        XCTAssertEqual(store.state(for: .allTime, viewer: "player").board?.entries.first?.touches, 96)
    }

    func testEmptyBoardIsCachedAndFailedRefreshKeepsIt() async {
        let store = LeaderboardBoardStore()
        var calls = 0
        for _ in 0..<2 {
            await store.load(.week, viewer: "player") {
                calls += 1
                return LeaderboardBoard(entries: [], around: [])
            }
        }
        XCTAssertEqual(calls, 1)
        await store.load(.week, viewer: "player", refresh: true) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(store.state(for: .week, viewer: "player").board?.entries.count, 0)
        XCTAssertNotNil(store.state(for: .week, viewer: "player").error)
    }

    func testFirstLoadFailureCanRetryAndRefreshRetainsVisibleScore() async {
        let store = LeaderboardBoardStore()
        await store.load(.week, viewer: "player") { throw URLError(.timedOut) }
        XCTAssertNil(store.state(for: .week, viewer: "player").board)
        await store.load(.week, viewer: "player") { self.board(74) }
        await store.load(.week, viewer: "player", refresh: true) {
            XCTAssertEqual(store.state(for: .week, viewer: "player").board?.entries.first?.touches, 74)
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(store.state(for: .week, viewer: "player").board?.entries.first?.touches, 74)
    }

    func testSwitchingTabsDoesNotCancelOrDuplicateInFlightFetch() async {
        let store = LeaderboardBoardStore()
        var calls = 0
        var finish: CheckedContinuation<LeaderboardBoard, Never>?
        let first = Task {
            await store.load(.week, viewer: "player") {
                calls += 1
                return await withCheckedContinuation { finish = $0 }
            }
        }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        XCTAssertNotNil(finish)
        first.cancel() // SwiftUI cancels its period task when another tab is selected.
        await store.load(.allTime, viewer: "player") { self.board(96) }
        let second = Task {
            await store.load(.week, viewer: "player") { calls += 1; return self.board(999) }
        }
        await Task.yield()
        finish?.resume(returning: board(74))
        await first.value; await second.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.state(for: .week, viewer: "player").board?.entries.first?.touches, 74)
    }

    func testAccountChangeDiscardsCacheAndLateResponses() async {
        let store = LeaderboardBoardStore()
        var finish: CheckedContinuation<LeaderboardBoard, Never>?
        let old = Task {
            await store.load(.week, viewer: "old") {
                await withCheckedContinuation { finish = $0 }
            }
        }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        XCTAssertNotNil(finish)
        await store.load(.week, viewer: "new") { self.board(12) }
        finish?.resume(returning: board(74))
        await old.value
        XCTAssertNil(store.state(for: .week, viewer: "old").board)
        XCTAssertEqual(store.state(for: .week, viewer: "new").board?.entries.first?.touches, 12)
        await store.load(.week, viewer: "old") { self.board(80) }
        XCTAssertEqual(store.state(for: .week, viewer: "old").board?.entries.first?.touches, 80)
    }
}
