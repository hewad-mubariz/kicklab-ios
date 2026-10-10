import Foundation

/// Small metadata commits are serialized with deletion; video bytes are copied
/// outside this lock. Late background writes cannot recreate a deleted library.
nonisolated enum AccountDataGuard {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var deleted = Set<String>()
    private static func key(_ owner: UUID, root: URL) -> String { root.standardizedFileURL.path + "/" + owner.uuidString }
    static func markDeleted(_ owner: UUID, root: URL) {
        lock.lock(); defer { lock.unlock() }
        deleted.insert(key(owner, root: root))
    }
    static func write<T>(owner: UUID?, root: URL, _ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if let owner {
            let marker = root.appendingPathComponent("PendingAccountDeletion/" + owner.uuidString)
            guard !deleted.contains(key(owner, root: root)), !FileManager.default.fileExists(atPath: marker.path) else {
                throw CancellationError()
            }
        }
        return try action()
    }
}

struct AccountDeletionStatus: Decodable {
    let requiresApple: Bool
    let deleted: Bool
    let userID: UUID
    enum CodingKeys: String, CodingKey {
        case requiresApple = "requires_apple", deleted, userID = "user_id"
    }
}

/// Calls the authenticated Edge Function. Only the server holds admin credentials.
struct AccountDeletionAPI {
    let configuration: AccountConfiguration
    var session: URLSession = .shared

    func prepare(token: String, userID: UUID) async throws -> AccountDeletionStatus {
        let data = try await request(method: "GET", token: token)
        guard let result = try? JSONDecoder().decode(AccountDeletionStatus.self, from: data),
              result.userID == userID else { throw AccountDeletionFailure.failed }
        return result
    }

    func delete(token: String, userID: UUID, appleCode: String?) async throws {
        let body = appleCode.map { ["apple_authorization_code": $0] } ?? [:]
        let data = try await request(method: "POST", token: token, body: try JSONEncoder().encode(body))
        struct Receipt: Decodable {
            let deleted: Bool
            let user_id: UUID
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.deleted, receipt.user_id == userID else { throw AccountDeletionFailure.failed }
    }

    private func request(method: String, token: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: configuration.projectURL.appendingPathComponent("functions/v1/delete-account"),
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AccountDeletionFailure.failed }
        guard response.statusCode == 200 else {
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            switch code {
            case "apple_deletion_unavailable": throw AccountDeletionFailure.appleUnavailable
            case "apple_account_mismatch": throw AccountDeletionFailure.appleMismatch
            case "apple_confirmation_required": throw AccountDeletionFailure.appleConfirmation
            case "sign_in_required": throw AccountDeletionFailure.signIn
            default: throw AccountDeletionFailure.failed
            }
        }
        return data
    }
}

enum AccountDeletionFailure: LocalizedError {
    case failed, appleUnavailable, appleMismatch, appleConfirmation, signIn
    var errorDescription: String? {
        switch self {
        case .failed: "Account deletion couldn’t be confirmed. Please try again."
        case .appleUnavailable: "Apple account deletion is temporarily unavailable. Your account has not been deleted. Please try again later."
        case .appleMismatch: "Use the Apple Account linked to this Juggle Dude account, then try again."
        case .appleConfirmation: "Apple confirmation couldn’t be completed. Please try deleting your account again."
        case .signIn: "Sign in again before deleting your account."
        }
    }
}
