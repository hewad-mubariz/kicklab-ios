import AuthenticationServices
import CryptoKit
import Security
import UIKit

@MainActor
final class SignInPresentation: NSObject, ASWebAuthenticationPresentationContextProviding, ASAuthorizationControllerPresentationContextProviding {
    static func window() throws -> UIWindow {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { throw AccountFailure.unavailableWindow }
        return window
    }

    let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }
}

@MainActor
final class BrowserSignIn {
    private var session: ASWebAuthenticationSession?
    private var presentation: SignInPresentation?

    func authenticate(url: URL) async throws -> URL {
        presentation = try SignInPresentation(window: SignInPresentation.window())
        defer { session = nil; presentation = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "juggledude") { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback, AccountConfiguration.acceptsCallback(callback) {
                    continuation.resume(returning: callback)
                } else { continuation.resume(throwing: AccountFailure.invalidCallback) }
            }
            session.presentationContextProvider = presentation
            self.session = session
            if !session.start() { continuation.resume(throwing: AccountFailure.unavailableWindow) }
        }
    }
}

struct AppleSignInResult {
    let idToken: String
    let nonce: String
    let fullName: String?
    let authorizationCode: String?
}

@MainActor
final class NativeAppleSignIn: NSObject, ASAuthorizationControllerDelegate {
    private var controller: ASAuthorizationController?
    private var presentation: SignInPresentation?
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var nonce: String?

    static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountFailure.nonce }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func signIn(requestScopes: Bool = true) async throws -> AppleSignInResult {
        let rawNonce = try Self.makeNonce()
        nonce = rawNonce
        presentation = try SignInPresentation(window: SignInPresentation.window())
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = requestScopes ? [.fullName, .email] : []
        request.nonce = SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
        defer { controller = nil; presentation = nil; nonce = nil; continuation = nil }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = presentation
            self.controller = controller
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8),
              let nonce else {
            continuation?.resume(throwing: AccountFailure.missingAppleToken); continuation = nil; return
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        continuation?.resume(returning: AppleSignInResult(idToken: token, nonce: nonce, fullName: name,
            authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
