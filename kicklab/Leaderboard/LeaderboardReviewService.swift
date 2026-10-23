import CryptoKit
import Foundation

@MainActor protocol LeaderboardReviewService: Sendable {
    func attempts(owner: UUID) async throws -> [LeaderboardAttempt]
    func begin(item: HistorySession, proposal: RankedStreakProposal, bytes: Int64, sha256: String) async throws -> LeaderboardAttempt
    func finish(id: UUID, owner: UUID) async throws -> LeaderboardAttempt
    func withdraw(id: UUID, owner: UUID) async throws
    func appeal(id: UUID, reason: String, owner: UUID) async throws
    func report(id: UUID, reason: String, owner: UUID) async throws
    func videoURL(attempt: LeaderboardAttempt, owner: UUID) async throws -> URL
    func upload(file: URL, attempt: LeaderboardAttempt, checkpoint: URL, accountRoot: URL,
                progress: @escaping @MainActor (Double) -> Void) async throws
}

@MainActor final class SupabaseLeaderboardReviewService: LeaderboardReviewService {
    private let config: AccountConfiguration
    private let token: (UUID) async throws -> String
    private let session: URLSession
    init(config: AccountConfiguration, session: URLSession = .shared, token: @escaping (UUID) async throws -> String) {
        self.config = config; self.token = token; self.session = session
    }
    func attempts(owner: UUID) async throws -> [LeaderboardAttempt] {
        let data = try await request("rest/v1/leaderboard_attempts?user_id=eq.\(owner.uuidString)&order=created_at.desc&limit=100", owner: owner)
        return try Self.decoder().decode([LeaderboardAttempt].self, from: data)
    }
    func begin(item: HistorySession, proposal: RankedStreakProposal, bytes: Int64, sha256: String) async throws -> LeaderboardAttempt {
        guard let owner = item.ownerID else { throw LeaderboardFailure.signIn }
        var fields: [String: Any] = [
            "p_session_id": item.id.uuidString, "p_count": proposal.count, "p_start_ms": proposal.startMS,
            "p_end_ms": proposal.endMS, "p_video_bytes": bytes, "p_sha256": sha256,
            "p_rules_version": LeaderboardRules.version, "p_size5_confirmed": true]
        if let report = item.touchReview {
            fields["p_touch_review"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
        }
        let data = try await rpc(item.touchReview == nil ? "begin_leaderboard_attempt" : "begin_leaderboard_attempt_with_review",
            owner: owner, fields: fields, single: true)
        let attempt = try Self.decoder().decode(LeaderboardAttempt.self, from: data)
        guard attempt.userID == owner, attempt.sessionID == item.id else { throw LeaderboardFailure.unavailable }
        return attempt
    }
    func finish(id: UUID, owner: UUID) async throws -> LeaderboardAttempt {
        let data = try await rpc("finish_leaderboard_attempt", owner: owner, fields: ["p_id": id.uuidString], single: true)
        let attempt = try Self.decoder().decode(LeaderboardAttempt.self, from: data)
        guard attempt.userID == owner, attempt.id == id else { throw LeaderboardFailure.unavailable }
        return attempt
    }
    func withdraw(id: UUID, owner: UUID) async throws {
        _ = try await rpc("withdraw_leaderboard_attempt", owner: owner, fields: ["p_id": id.uuidString])
    }
    func appeal(id: UUID, reason: String, owner: UUID) async throws {
        _ = try await rpc("appeal_leaderboard_attempt", owner: owner, fields: ["p_id": id.uuidString, "p_reason": reason])
    }
    func report(id: UUID, reason: String, owner: UUID) async throws {
        _ = try await rpc("report_leaderboard_attempt", owner: owner, fields: ["p_id": id.uuidString, "p_reason": reason])
    }
    func videoURL(attempt: LeaderboardAttempt, owner: UUID) async throws -> URL {
        guard attempt.userID == owner else { throw LeaderboardFailure.signIn }
        guard attempt.hasPrivateVideo else { throw LeaderboardFailure.originalRequired }
        struct Link: Decodable { let signedURL: String }
        let data = try await request("storage/v1/object/sign/leaderboard-originals/\(attempt.objectPath)",
            method: "POST", owner: owner, body: JSONSerialization.data(withJSONObject: ["expiresIn": 300]))
        let signed = try JSONDecoder().decode(Link.self, from: data).signedURL
        guard let url = URL(string: config.projectURL.absoluteString + "/storage/v1" + signed),
              url.host == config.projectURL.host else { throw LeaderboardFailure.unavailable }
        return url
    }
    private func rpc(_ name: String, owner: UUID, fields: [String: Any], single: Bool = false) async throws -> Data {
        try await request("rest/v1/rpc/\(name)", method: "POST", owner: owner, body: JSONSerialization.data(withJSONObject: fields), single: single)
    }
    private func request(_ path: String, method: String = "GET", owner: UUID, body: Data? = nil, single: Bool = false) async throws -> Data {
        guard let url = URL(string: config.projectURL.absoluteString + "/" + path) else { throw LeaderboardFailure.unavailable }
        var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = body; req.timeoutInterval = 30
        req.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await token(owner))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Table-valued RPCs otherwise return an array, even for one row.
        if single { req.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw LeaderboardFailure.unavailable }
        guard (200...299).contains(http.statusCode) else { throw Self.failure(http.statusCode) }
        return data
    }
    private static func failure(_ status: Int) -> LeaderboardFailure {
        switch status {
        case 401, 403: .signIn
        case 429: .limit
        case 400, 409, 422: .conflict
        default: .unavailable
        }
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let value = try d.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Invalid date"))
        }
        return decoder
    }

    /// TUS uses fixed 6 MiB chunks. Only a bounded chunk is resident; the original
    /// stays on disk. HEAD reconciles a lost PATCH response before retrying.
    func upload(file: URL, attempt: LeaderboardAttempt, checkpoint: URL, accountRoot: URL,
                progress: @escaping @MainActor (Double) -> Void) async throws {
        let uploader = LeaderboardVideoUpload(config: config, session: session, token: token)
        try await uploader.run(file: file, attempt: attempt, checkpoint: checkpoint, accountRoot: accountRoot, progress: progress)
    }
}

nonisolated enum LeaderboardVideoFingerprint {
    static func read(_ url: URL) throws -> (bytes: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), size: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); size += Int64(data.count)
            guard size <= LeaderboardRules.maximumVideoBytes else { throw LeaderboardFailure.tooLarge }
            hash.update(data: data)
        }
        guard size > 0 else { throw LeaderboardFailure.originalRequired }
        return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
