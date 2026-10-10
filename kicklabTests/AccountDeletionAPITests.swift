import XCTest
@testable import kicklab

@MainActor
final class AccountDeletionAPITests: XCTestCase {
    private let owner = UUID()
    private var session: URLSession!
    private var api: AccountDeletionAPI!
    override func setUpWithError() throws {
        let config = try AccountConfiguration(values: ["SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test", "AUTH_REDIRECT_URL": "juggledude://auth/callback"])
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [DeletionURLProtocol.self]
        session = URLSession(configuration: sessionConfig)
        api = AccountDeletionAPI(configuration: config, session: session)
        DeletionURLProtocol.status = 200
        DeletionURLProtocol.captured = nil
    }
    override func tearDown() { session.invalidateAndCancel() }

    func testPreflightUsesCurrentUserTokenAndOnlyClientPublishableKey() async throws {
        DeletionURLProtocol.data = try JSONSerialization.data(withJSONObject: [
            "user_id": owner.uuidString, "deleted": false, "requires_apple": true])
        let status = try await api.prepare(token: "test-user-token", userID: owner)
        XCTAssertTrue(status.requiresApple)
        let request = try XCTUnwrap(DeletionURLProtocol.captured)
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/delete-account")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-user-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
    }

    func testDeletionRequiresAReceiptForTheSameAccount() async throws {
        DeletionURLProtocol.data = try JSONSerialization.data(withJSONObject: ["deleted": true, "user_id": UUID().uuidString])
        do {
            try await api.delete(token: "test-user-token", userID: owner, appleCode: nil)
            XCTFail("Accepted another user's receipt")
        } catch { XCTAssertTrue(error is AccountDeletionFailure) }
        DeletionURLProtocol.data = try JSONSerialization.data(withJSONObject: ["deleted": true, "user_id": owner.uuidString])
        try await api.delete(token: "test-user-token", userID: owner, appleCode: nil)
        XCTAssertEqual(DeletionURLProtocol.captured?.httpMethod, "POST")
    }

    func testUnconfirmedDeletionAndUnknownProviderErrorsAreNotSuccessOrLeaked() async throws {
        DeletionURLProtocol.data = try JSONSerialization.data(withJSONObject: ["deleted": false, "user_id": owner.uuidString])
        do { try await api.delete(token: "test-user-token", userID: owner, appleCode: nil); XCTFail("Accepted false receipt") }
        catch { XCTAssertTrue(error is AccountDeletionFailure) }
        DeletionURLProtocol.status = 503
        DeletionURLProtocol.data = Data(#"{"error":"private-token-provider-details"}"#.utf8)
        do { _ = try await api.prepare(token: "test-user-token", userID: owner); XCTFail("Accepted provider error") }
        catch { XCTAssertEqual(error.localizedDescription, AccountDeletionFailure.failed.localizedDescription) }
    }
}

private final class DeletionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var data = Data()
    nonisolated(unsafe) static var captured: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
