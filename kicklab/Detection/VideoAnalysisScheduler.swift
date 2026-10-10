import Foundation

/// One offline detector pass at a time, including imports and saved-pixel replay.
/// A cancelled waiter never loads a model; an active owner releases its place
/// only after its reader/model work has actually stopped.
actor VideoAnalysisScheduler {
    static let shared = VideoAnalysisScheduler()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var owner: UUID?
    private var waiters: [Waiter] = []
    var queuedCount: Int { waiters.count }

    func perform<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await acquire(id)
        do {
            try Task.checkCancellation()
            let result = try await work()
            release(id)
            return result
        } catch {
            release(id)
            throw error
        }
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil { owner = id; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty { owner = nil }
        else {
            let next = waiters.removeFirst()
            owner = next.id
            next.continuation.resume()
        }
    }
}
