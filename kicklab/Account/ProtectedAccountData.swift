import UIKit

/// Retain Complete Protection for account/history files. Work waits for unlock
/// instead of treating protected data as corrupt or publishing an empty library.
@MainActor
enum ProtectedAccountData {
    static func waitUntilAvailable() async throws {
        while !UIApplication.shared.isProtectedDataAvailable {
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }
    static var isAvailable: Bool { UIApplication.shared.isProtectedDataAvailable }
}
