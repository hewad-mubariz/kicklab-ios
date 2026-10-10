import Combine
import Foundation

struct LeaderboardBoard {
    let entries: [LeaderboardEntry]
    let around: [LeaderboardEntry]
}

/// In-memory results for one visit to the leaderboard. Empty boards are cached
/// too; a refresh replaces only its period. Accounts never share cached results.
@MainActor
final class LeaderboardBoardStore: ObservableObject {
    struct State {
        var board: LeaderboardBoard?
        var error: String?
    }
    private struct Request {
        let id: UUID
        let task: Task<LeaderboardBoard, Error>
    }
    @Published private var states: [LeaderboardPeriod: State] = [:]
    private var viewer: String?
    private var generation = UUID()
    private var requests: [LeaderboardPeriod: Request] = [:]

    func state(for period: LeaderboardPeriod, viewer: String) -> State {
        self.viewer == viewer ? states[period, default: State()] : State()
    }

    func load(_ period: LeaderboardPeriod, viewer: String, refresh: Bool = false,
              fetch: @escaping @MainActor () async throws -> LeaderboardBoard) async {
        if self.viewer != viewer {
            requests.values.forEach { $0.task.cancel() }
            requests = [:]
            states = [:]
            generation = UUID()
            self.viewer = viewer
        }
        if !refresh, states[period]?.board != nil { return }
        if let pending = requests[period] {
            _ = try? await pending.task.value
            return
        }
        let current = generation
        let request = Request(id: UUID(), task: Task { try await fetch() })
        requests[period] = request
        states[period, default: State()].error = nil
        defer {
            if generation == current, requests[period]?.id == request.id {
                requests[period] = nil
            }
        }
        do {
            // Tab changes may cancel the view's task, but this fetch can finish
            // warming that tab. Only an account change invalidates its result.
            let board = try await request.task.value
            guard generation == current, !request.task.isCancelled else { return }
            states[period] = State(board: board)
        } catch {
            guard generation == current, !request.task.isCancelled else { return }
            states[period, default: State()].error = PlayerDataError.requestFailed.localizedDescription
        }
    }
}
