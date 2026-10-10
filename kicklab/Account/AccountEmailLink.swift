import Foundation

/// Email links open the verified website domain directly in iOS. The one-use
/// token stays in the fragment, so a web fallback never sends it to website logs.
struct AccountEmailLink: Sendable {
    let tokenHash: String
    let type: String

    static func matchesEndpoint(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.port == nil else { return false }
        if url.scheme?.lowercased() == "https", url.host?.lowercased() == "juggledude.com" {
            return url.path == "/auth/email" || url.path == "/auth/email/"
        }
        return url.scheme?.lowercased() == "juggledude" && url.host?.lowercased() == "auth" && url.path == "/email"
    }

    init(url: URL) throws {
        guard Self.matchesEndpoint(url), url.query == nil,
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
              fragment.count <= 512 else { throw AccountFailure.invalidCallback }
        var parameters = URLComponents()
        parameters.percentEncodedQuery = fragment
        let items = parameters.queryItems ?? []
        guard items.count == 2,
              items.filter({ $0.name == "token_hash" }).count == 1,
              items.filter({ $0.name == "type" }).count == 1,
              let token = items.first(where: { $0.name == "token_hash" })?.value,
              token.range(of: #"\Apkce_[a-fA-F0-9]{40,128}\z"#, options: .regularExpression) != nil,
              let type = items.first(where: { $0.name == "type" })?.value,
              ["magiclink", "signup"].contains(type) else { throw AccountFailure.invalidCallback }
        self.tokenHash = token
        self.type = type
    }

    func verificationURL(configuration: AccountConfiguration) -> URL {
        var components = URLComponents(url: configuration.projectURL.appendingPathComponent("auth/v1/verify"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "token", value: tokenHash),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "redirect_to", value: configuration.redirectURL.absoluteString)
        ]
        return components.url!
    }

    func callback(from response: HTTPURLResponse) throws -> URL {
        guard [302, 303].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location), AccountConfiguration.acceptsCallback(url) else {
            throw AccountFailure.invalidCallback
        }
        return url
    }

    func resolve(configuration: AccountConfiguration) async throws -> URL {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        settings.timeoutIntervalForRequest = 25
        let session = URLSession(configuration: settings, delegate: EmailVerificationRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: verificationURL(configuration: configuration))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Stop at Supabase's redirect. The Auth SDK then exchanges its code using
        // the original device's Keychain PKCE verifier; no browser or web session.
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AccountFailure.invalidCallback }
        return try callback(from: response)
    }
}

private final class EmailVerificationRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
