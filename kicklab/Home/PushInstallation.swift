import Foundation
import Security

nonisolated struct PushInstallationCredential: Codable, Equatable {
    let id: UUID
    let secret: String
    var revision: Int64
}

@MainActor
protocol PushInstallationVault {
    func load() throws -> PushInstallationCredential?
    func save(_ value: PushInstallationCredential) throws
}

/// An installation capability, separate from account sign-in. Never store the
/// APNs token here: Apple supplies its current value each time we register.
@MainActor
struct KeychainPushInstallationVault: PushInstallationVault {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.juggledude") + ".push-installation",
         kSecAttrAccount as String: "installation"]
    }
    func load() throws -> PushInstallationCredential? {
        var query = query
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw PushRegistrationError.storage }
        return try JSONDecoder().decode(PushInstallationCredential.self, from: data)
    }
    func save(_ value: PushInstallationCredential) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PushRegistrationError.storage }
        } else if status != errSecSuccess { throw PushRegistrationError.storage }
    }
    static func create() throws -> PushInstallationCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PushRegistrationError.storage }
        return PushInstallationCredential(id: UUID(), secret: bytes.map { String(format: "%02x", $0) }.joined(), revision: 0)
    }
}

nonisolated enum PushRegistrationError: Error { case storage, unavailable, rejected }

nonisolated struct PushRegistration: Encodable, Equatable, Sendable {
    let installationId: UUID
    let secret: String
    let revision: Int64
    let bundleId: String
    let environment: String
    let token: String?
    let trainingEnabled: Bool
    let leaderboardEnabled: Bool
    let notificationRoutesVersion = 1
    let dailyReminderEnabled: Bool
    let locale: String
    let reminderMinute: Int
    let timeZone: String
    let deliveryMode = "server"
}

@MainActor
protocol PushRegistrationClient {
    func synchronize(_ registration: PushRegistration, accessToken: String?) async throws
}

@MainActor
struct HTTPPushRegistrationClient: PushRegistrationClient {
    let configuration: AccountConfiguration
    private static let session = URLSession(configuration: .ephemeral, delegate: PushRedirectGuard(), delegateQueue: nil)
    func synchronize(_ registration: PushRegistration, accessToken: String?) async throws {
        var request = URLRequest(url: configuration.projectURL.appendingPathComponent("functions/v1/push-installation"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(registration)
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try? JSONDecoder().decode(Receipt.self, from: data), result.saved else {
            throw PushRegistrationError.rejected
        }
    }
    private struct Receipt: Decodable { let saved: Bool }
}

/// Never forward an installation capability or account token to a redirect.
nonisolated private final class PushRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
