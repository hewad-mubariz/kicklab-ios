import Foundation

/// Cancellation shared by the UI and capture queue. Stop takes effect before
/// the queue gets to its cleanup block, so no new frame starts processing.
nonisolated final class CaptureRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}
