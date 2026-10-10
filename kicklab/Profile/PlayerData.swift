import Foundation

struct PlayerProfile: Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var countryCode: String?
    var avatarPath: String?
    var leaderboardVisible: Bool
    enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", countryCode = "country_code"
        case avatarPath = "avatar_path", leaderboardVisible = "leaderboard_visible"
    }
}

nonisolated struct SavedJugglingResult: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case recording, gallery }
    let id: UUID
    let ownerID: UUID
    let touches: Int
    let durationMS: Int
    let source: Source
    let completedAt: Date
    let appVersion: String
    let counterVersion: String

    init(id: UUID = UUID(), ownerID: UUID, touches: Int, duration: TimeInterval,
         source: Source, completedAt: Date = Date(), appVersion: String = "1.0", counterVersion: String = "juggling-v1") throws {
        guard (0...1_000_000).contains(touches), duration.isFinite, duration > 0, duration <= 86400 else {
            throw PlayerDataError.invalidResult
        }
        self.id = id; self.ownerID = ownerID; self.touches = touches
        durationMS = max(1, Int((duration * 1000).rounded()))
        self.source = source
        self.completedAt = Date(timeIntervalSince1970: floor(completedAt.timeIntervalSince1970))
        self.appVersion = appVersion; self.counterVersion = counterVersion
    }
}

struct RankedPlayer: Decodable, Sendable {
    let rank: Int
    let userID: UUID
    let displayName: String
    let countryCode: String?
    let avatarPath: String?
    let touches: Int
    let isYou: Bool
    enum CodingKeys: String, CodingKey {
        case rank, touches, userID = "user_id", displayName = "display_name", countryCode = "country_code"
        case avatarPath = "avatar_path", isYou = "is_you"
    }
}

struct JugglingLeaderboard: Decodable, Sendable {
    let entries: [RankedPlayer]
    let aroundMe: [RankedPlayer]
    let totalPlayers: Int
    enum CodingKeys: String, CodingKey { case entries, aroundMe = "around_me", totalPlayers = "total_players" }
}

nonisolated enum PlayerDataError: LocalizedError {
    case unavailable, signIn, invalidResult, requestFailed, invalidProfile
    var errorDescription: String? {
        switch self {
        case .unavailable: "Account storage is unavailable in this build."
        case .signIn: "Sign in again to sync your account."
        case .invalidResult: "This session could not be saved."
        case .requestFailed: "We couldn’t sync with Juggle Dude. Check your connection and try again."
        case .invalidProfile: "Choose a name of 1–40 characters and a valid country."
        }
    }
}

@MainActor
protocol PlayerDataService: Sendable {
    func profile(userID: UUID) async throws -> PlayerProfile
    func personalBest(userID: UUID) async throws -> Int
    func saveProfile(_ profile: PlayerProfile) async throws -> PlayerProfile
    func submit(_ result: SavedJugglingResult) async throws
    func history(userID: UUID, before: SessionHistoryCursor?) async throws -> SessionHistoryPage
    func leaderboard(period: String, country: String?, userID: UUID?) async throws -> JugglingLeaderboard
    func avatarURL(path: String, userID: UUID?) async throws -> URL
    func uploadAvatar(_ jpeg: Data, userID: UUID) async throws
    func deleteAvatar(userID: UUID) async throws
}

/// Each request obtains a fresh SDK-managed token and checks the expected owner.
/// No service-role key, session token or provider secret is stored by this client.
@MainActor
final class SupabasePlayerService: PlayerDataService {
    private let config: AccountConfiguration
    private let token: (UUID) async throws -> String
    private let session: URLSession
    init(config: AccountConfiguration, session: URLSession = .shared, token: @escaping (UUID) async throws -> String) {
        self.config = config; self.session = session; self.token = token
    }

    func profile(userID: UUID) async throws -> PlayerProfile {
        let data = try await request("rest/v1/profiles", query: [URLQueryItem(name: "id", value: "eq.\(userID.uuidString)")], userID: userID)
        guard let profile = try JSONDecoder().decode([PlayerProfile].self, from: data).first else { throw PlayerDataError.requestFailed }
        return profile
    }

    func personalBest(userID: UUID) async throws -> Int {
        struct Score: Decodable { let touch_count: Int }
        let data = try await request("rest/v1/juggling_sessions", query: [
            .init(name: "select", value: "touch_count"), .init(name: "score_status", value: "neq.rejected"),
            .init(name: "order", value: "touch_count.desc"), .init(name: "limit", value: "1")], userID: userID)
        return try JSONDecoder().decode([Score].self, from: data).first?.touch_count ?? 0
    }

    func saveProfile(_ profile: PlayerProfile) async throws -> PlayerProfile {
        var fields: [String: Any] = ["display_name": profile.displayName,
            "leaderboard_visible": profile.leaderboardVisible]
        fields["country_code"] = profile.countryCode.map { $0 as Any } ?? NSNull()
        fields["avatar_path"] = profile.avatarPath.map { $0 as Any } ?? NSNull()
        let data = try await request("rest/v1/profiles", method: "PATCH",
            query: [.init(name: "id", value: "eq.\(profile.id.uuidString)")],
            body: JSONSerialization.data(withJSONObject: fields), userID: profile.id,
            headers: ["Prefer": "return=representation"])
        guard let saved = try JSONDecoder().decode([PlayerProfile].self, from: data).first else { throw PlayerDataError.requestFailed }
        return saved
    }

    func submit(_ result: SavedJugglingResult) async throws {
        let date = ISO8601DateFormatter().string(from: result.completedAt)
        let fields: [String: Any] = ["p_id": result.id.uuidString, "p_touch_count": result.touches,
            "p_duration_ms": result.durationMS, "p_source": result.source.rawValue,
            "p_completed_at": date, "p_app_version": result.appVersion, "p_counter_version": result.counterVersion]
        _ = try await request("rest/v1/rpc/submit_juggling_session", method: "POST",
            body: JSONSerialization.data(withJSONObject: fields), userID: result.ownerID)
    }

    func history(userID: UUID, before: SessionHistoryCursor?) async throws -> SessionHistoryPage {
        let data = try await request("rest/v1/juggling_sessions",
            query: SessionHistoryPage.query(userID: userID, before: before), userID: userID)
        return try SessionHistoryPage.decode(data, owner: userID)
    }

    func leaderboard(period: String, country: String?, userID: UUID?) async throws -> JugglingLeaderboard {
        let fields: [String: Any] = ["p_period": period, "p_country": country.map { $0 as Any } ?? NSNull(), "p_limit": 50]
        let data = try await request("rest/v1/rpc/juggling_leaderboard", method: "POST",
            body: JSONSerialization.data(withJSONObject: fields), userID: userID)
        return try JSONDecoder().decode(JugglingLeaderboard.self, from: data)
    }

    func avatarURL(path: String, userID: UUID?) async throws -> URL {
        struct Link: Decodable { let signedURL: String }
        let data = try await request("storage/v1/object/sign/avatars/\(path)", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["expiresIn": 300]), userID: userID)
        let link = try JSONDecoder().decode(Link.self, from: data)
        guard let url = URL(string: config.projectURL.absoluteString + "/storage/v1" + link.signedURL) else { throw PlayerDataError.requestFailed }
        return url
    }

    func uploadAvatar(_ jpeg: Data, userID: UUID) async throws {
        guard jpeg.count <= 2_097_152 else { throw PlayerDataError.requestFailed }
        _ = try await request("storage/v1/object/avatars/\(userID.uuidString.lowercased())/avatar.jpg",
            method: "POST", body: jpeg, userID: userID,
            headers: ["Content-Type": "image/jpeg", "x-upsert": "true", "Cache-Control": "max-age=0"])
    }

    func deleteAvatar(userID: UUID) async throws {
        _ = try await request("storage/v1/object/avatars", method: "DELETE",
            body: JSONSerialization.data(withJSONObject: ["prefixes": ["\(userID.uuidString.lowercased())/avatar.jpg"]]), userID: userID)
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: Data? = nil, userID: UUID?, headers: [String: String] = [:]) async throws -> Data {
        var components = URLComponents(url: config.projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // A literal UTC offset '+' is not a form-encoded space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userID { request.setValue("Bearer \(try await token(userID))", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            // Server errors can contain identifiers and request data. Keep them out of UI/logs.
            throw PlayerDataError.requestFailed
        }
        return data
    }
}
