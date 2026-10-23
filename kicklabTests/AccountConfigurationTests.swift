import XCTest
@testable import kicklab

@MainActor
final class AccountConfigurationTests: XCTestCase {
    private var values: [String: String] {
        ["SUPABASE_URL": "https://example.supabase.co",
         "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test",
         "AUTH_REDIRECT_URL": "juggledude://auth/callback"]
    }

    func testExistingConfigurationKeepsItsAuthEndpointAndSessionIdentity() throws {
        let configuration = try AccountConfiguration(values: values)
        XCTAssertEqual(configuration.authURL.absoluteString, "https://example.supabase.co/auth/v1")
        XCTAssertEqual(configuration.sessionStorageKey, "juggledude.example.supabase.co.session")
    }

    func testBrandedDomainKeepsProjectSessionAndCallbackIdentity() throws {
        let original = try AccountConfiguration(values: values)
        for origin in ["https://auth.juggledude.com", "https://auth.juggledude.com/"] {
            var brandedValues = values
            brandedValues["SUPABASE_AUTH_URL"] = origin
            let branded = try AccountConfiguration(values: brandedValues)
            XCTAssertEqual(branded.authURL.absoluteString, "https://auth.juggledude.com/auth/v1")
            XCTAssertEqual(branded.projectURL, original.projectURL)
            XCTAssertEqual(branded.sessionStorageKey, original.sessionStorageKey)
            XCTAssertEqual(branded.publishableKey, original.publishableKey)
            XCTAssertEqual(branded.redirectURL, original.redirectURL)
        }
    }

    func testMalformedAuthOverrideFailsInsteadOfSendingCredentialsElsewhere() {
        for origin in ["", "http://auth.juggledude.com", "https:///", "/auth/v1",
                       "https://user@auth.juggledude.com", "https://user:password@auth.juggledude.com",
                       "https://auth.juggledude.com:443", "https://auth.juggledude.com/auth/v1",
                       "https://auth.juggledude.com?next=other", "https://auth.juggledude.com#fragment",
                       "https://YOUR_PROJECT.supabase.co"] {
            var invalid = values
            invalid["SUPABASE_AUTH_URL"] = origin
            XCTAssertThrowsError(try AccountConfiguration(values: invalid), origin)
        }
    }

    func testEmailVerificationUsesSameBrandedAuthEndpoint() throws {
        var brandedValues = values
        brandedValues["SUPABASE_AUTH_URL"] = "https://auth.juggledude.com"
        let configuration = try AccountConfiguration(values: brandedValues)
        let token = "pkce_" + String(repeating: "a", count: 56)
        let link = try AccountEmailLink(url: URL(string: "https://juggledude.com/auth/email/#token_hash=\(token)&type=magiclink")!)
        let url = link.verificationURL(configuration: configuration)
        XCTAssertEqual(url.host, "auth.juggledude.com")
        XCTAssertEqual(url.path, "/auth/v1/verify")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "token" }?.value, token)
        XCTAssertEqual(items?.first { $0.name == "redirect_to" }?.value, "juggledude://auth/callback")
    }
}
