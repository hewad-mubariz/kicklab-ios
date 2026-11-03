import GoogleSignIn
import XCTest
@testable import kicklab

@MainActor
final class NativeGoogleSignInTests: XCTestCase {
    func testBundledNativeClientUsesExistingBackendAudienceAndOwnCallback() throws {
        let config = try NativeGoogleSignIn.Configuration(info: Bundle.main.infoDictionary ?? [:])
        XCTAssertEqual(config.clientID, "312611098464-ut664skmcfjlg7nnck966cnfq9824a9v.apps.googleusercontent.com")
        XCTAssertEqual(config.serverClientID, "312611098464-dkqd08atv84ne68qpj772j4t0ivn8qus.apps.googleusercontent.com")
        XCTAssertEqual(config.callbackScheme, "com.googleusercontent.apps.312611098464-ut664skmcfjlg7nnck966cnfq9824a9v")
        XCTAssertFalse(AccountConfiguration.acceptsIncomingLink(URL(string: config.callbackScheme + ":/oauthredirect?code=test")!))
        XCTAssertFalse(NativeGoogleSignIn.handle(URL(string: "juggledude://auth/callback?code=test")!))
    }

    func testMissingClientOrCallbackFailsBeforeCallingGoogleSDK() {
        XCTAssertThrowsError(try NativeGoogleSignIn.Configuration(info: [:]))
        var info = Bundle.main.infoDictionary ?? [:]
        info["CFBundleURLTypes"] = []
        XCTAssertThrowsError(try NativeGoogleSignIn.Configuration(info: info))
        info = Bundle.main.infoDictionary ?? [:]
        info["GIDServerClientID"] = info["GIDClientID"]
        XCTAssertThrowsError(try NativeGoogleSignIn.Configuration(info: info))
    }

    func testOnlyGoogleCancellationIsQuiet() {
        let cancelled = NSError(domain: kGIDSignInErrorDomain, code: GIDSignInError.canceled.rawValue)
        XCTAssertTrue(NativeGoogleSignIn.normalizedError(cancelled) is CancellationError)
        let other = NSError(domain: "Other", code: cancelled.code)
        XCTAssertFalse(NativeGoogleSignIn.normalizedError(other) is CancellationError)
        let network = URLError(.notConnectedToInternet)
        XCTAssertEqual((NativeGoogleSignIn.normalizedError(network) as? URLError)?.code, .notConnectedToInternet)
    }
}
