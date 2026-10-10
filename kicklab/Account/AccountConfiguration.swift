import Foundation

struct AccountConfiguration {
    let projectURL: URL
    let publishableKey: String
    let redirectURL: URL

    init(values: [String: String]) throws {
        guard let rawURL = values["SUPABASE_URL"], let url = URL(string: rawURL),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              !host.contains("YOUR_PROJECT"), url.user == nil, url.password == nil,
              let key = values["SUPABASE_PUBLISHABLE_KEY"],
              key.hasPrefix("sb_publishable_"), !key.contains("REPLACE_ME"),
              let redirect = values["AUTH_REDIRECT_URL"].flatMap(URL.init(string:)),
              redirect.absoluteString == "juggledude://auth/callback" else {
            throw AccountFailure.configuration
        }
        projectURL = url
        publishableKey = key
        redirectURL = redirect
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let path = bundle.url(forResource: "SupabaseConfig", withExtension: "plist"),
              let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: String] else {
            throw AccountFailure.configuration
        }
        return try Self(values: values)
    }

    static func acceptsCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "juggledude" && url.host?.lowercased() == "auth" &&
        url.path == "/callback" && url.user == nil && url.password == nil && url.port == nil
    }

    static func acceptsIncomingLink(_ url: URL) -> Bool {
        acceptsCallback(url) || AccountEmailLink.matchesEndpoint(url)
    }

    static func normalizedEmail(_ text: String) -> String? {
        let email = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.count <= 254,
              email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { return nil }
        return email
    }
}

enum AccountFailure: LocalizedError {
    case configuration, invalidEmail, invalidCallback, missingAppleToken, unavailableWindow, nonce

    var errorDescription: String? {
        switch self {
        case .configuration: "Sign-in is unavailable in this build. You can still train as a guest."
        case .invalidEmail: "Enter a valid email address."
        case .invalidCallback: "This sign-in link is invalid. Request a new link and open it on this device."
        case .missingAppleToken: "Apple could not complete sign-in. Please try again."
        case .unavailableWindow: "Please reopen the sign-in screen and try again."
        case .nonce: "Unable to start secure sign-in. Please try again."
        }
    }
}
