import XCTest
@testable import kicklab

@MainActor
final class AccountEmailLinkTests: XCTestCase {
    private let token = "pkce_" + String(repeating: "a", count: 56)

    func testUniversalAndExplicitFallbackLinksBuildOnlySupabaseVerificationRequest() throws {
        let config = try configuration()
        for base in ["https://juggledude.com/auth/email/", "https://juggledude.com/auth/email", "juggledude://auth/email"] {
            for type in ["signup", "magiclink"] {
                let url = URL(string: "\(base)#token_hash=\(token)&type=\(type)")!
                XCTAssertTrue(AccountConfiguration.acceptsIncomingLink(url))
                let link = try AccountEmailLink(url: url)
                let request = link.verificationURL(configuration: config)
                XCTAssertEqual(request.scheme, "https")
                XCTAssertEqual(request.host, "example.supabase.co")
                XCTAssertEqual(request.path, "/auth/v1/verify")
                let parameters = URLComponents(url: request, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(parameters.first(where: { $0.name == "token" })?.value, token)
                XCTAssertEqual(parameters.first(where: { $0.name == "type" })?.value, type)
                XCTAssertEqual(parameters.first(where: { $0.name == "redirect_to" })?.value, "juggledude://auth/callback")
            }
        }
    }

    func testRejectsUntrustedOriginsAndAmbiguousOrMalformedTokens() {
        let valid = "#token_hash=\(token)&type=magiclink"
        for base in ["http://juggledude.com/auth/email/", "https://juggledude.com.evil.example/auth/email/",
                     "https://user@juggledude.com/auth/email/", "https://juggledude.com:443/auth/email/",
                     "https://juggledude.com/auth/other/", "juggledude://evil/email"] {
            XCTAssertThrowsError(try AccountEmailLink(url: URL(string: base + valid)!))
        }
        for suffix in ["", "?token_hash=\(token)&type=magiclink", "?next=evil" + valid,
                       valid + "&type=signup", valid + "&next=https://evil.example",
                       "#token_hash=\(token)&type=recovery", "#token_hash=plain-token&type=magiclink",
                       "#token_hash=\(token)%0A&type=magiclink", "#token_hash=\(token)&token_hash=\(token)"] {
            XCTAssertThrowsError(try AccountEmailLink(url: URL(string: "https://juggledude.com/auth/email/" + suffix)!))
        }
    }

    func testAcceptsOnlySupabaseRedirectToTheExistingPKCECallback() throws {
        let link = try AccountEmailLink(url: URL(string: "https://juggledude.com/auth/email/#token_hash=\(token)&type=magiclink")!)
        let verification = link.verificationURL(configuration: try configuration())
        let callback = "juggledude://auth/callback?code=test-code"
        for status in [302, 303] {
            let response = HTTPURLResponse(url: verification, statusCode: status, httpVersion: nil, headerFields: ["Location": callback])!
            XCTAssertEqual(try link.callback(from: response).absoluteString, callback)
        }
        for destination in ["https://evil.example/?code=test", "juggledude://evil/callback?code=test", "https://juggledude.com/auth/email/"] {
            let response = HTTPURLResponse(url: verification, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination])!
            XCTAssertThrowsError(try link.callback(from: response))
        }
        for status in [200, 400, 500] {
            let response = HTTPURLResponse(url: verification, statusCode: status, httpVersion: nil, headerFields: ["Location": callback])!
            XCTAssertThrowsError(try link.callback(from: response))
        }
    }

    private func configuration() throws -> AccountConfiguration {
        try AccountConfiguration(values: ["SUPABASE_URL": "https://example.supabase.co", "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test", "AUTH_REDIRECT_URL": "juggledude://auth/callback"])
    }
}
