import CryptoKit
import GoogleSignIn
import UIKit

struct GoogleSignInTokens {
    let idToken: String
    let nonce: String
}

/// Google handles its consent UI; Supabase remains the only app-session authority.
@MainActor
enum NativeGoogleSignIn {
    struct Configuration {
        let clientID: String
        let serverClientID: String
        var callbackScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }

        init(info: [String: Any]) throws {
            guard let clientID = info["GIDClientID"] as? String,
                  let serverClientID = info["GIDServerClientID"] as? String,
                  clientID.hasSuffix(".apps.googleusercontent.com"),
                  serverClientID.hasSuffix(".apps.googleusercontent.com"),
                  clientID != serverClientID else { throw AccountFailure.configuration }
            self.clientID = clientID; self.serverClientID = serverClientID
            let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
                .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            guard schemes.contains(callbackScheme) else { throw AccountFailure.configuration }
        }
    }

    static func signIn() async throws -> GoogleSignInTokens {
        let config = try Configuration(info: Bundle.main.infoDictionary ?? [:])
        guard var presenter = try SignInPresentation.window().rootViewController else {
            throw AccountFailure.unavailableWindow
        }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        let nonce = try NativeAppleSignIn.makeNonce()
        let hashedNonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: config.clientID,
                                                                  serverClientID: config.serverClientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil,
                additionalScopes: nil, nonce: hashedNonce)
            guard let token = result.user.idToken?.tokenString, !token.isEmpty else {
                throw AccountFailure.missingGoogleToken
            }
            return GoogleSignInTokens(idToken: token, nonce: nonce)
        } catch {
            throw normalizedError(error)
        }
    }

    static func normalizedError(_ error: Error) -> Error {
        let failure = error as NSError
        if failure.domain == kGIDSignInErrorDomain && failure.code == GIDSignInError.canceled.rawValue {
            return CancellationError()
        }
        return error
    }

    static func handle(_ url: URL) -> Bool {
        guard let config = try? Configuration(info: Bundle.main.infoDictionary ?? [:]),
              url.scheme == config.callbackScheme else { return false }
        return GIDSignIn.sharedInstance.handle(url)
    }

    /// Clear local Google credentials; do not revoke the person's Google account access.
    static func signOut() { GIDSignIn.sharedInstance.signOut() }
}
