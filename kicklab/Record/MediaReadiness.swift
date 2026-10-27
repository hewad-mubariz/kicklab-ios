import Foundation

/// Bounded, cancellable readiness waiting. A failed player never becomes an
/// endless loading screen, and cancellation never turns sleep into a busy loop.
@MainActor
enum MediaReadiness {
    enum Failure: LocalizedError {
        case unavailable, timedOut
        var errorDescription: String? {
            String(localized: "The video could not open. Please close it and try again.")
        }
    }
    static func wait(timeout: Duration = .seconds(15),
                     ready: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if try ready() { return }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
