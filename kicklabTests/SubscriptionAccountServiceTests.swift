import XCTest
import StoreKit
@testable import kicklab

@MainActor
final class SubscriptionAccountServiceTests: XCTestCase {
    private let owner = UUID()
    private var session: URLSession!
    private var config: AccountConfiguration!

    override func setUp() async throws {
        config = try AccountConfiguration(values: ["SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test", "AUTH_REDIRECT_URL": "juggledude://auth/callback"])
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [SubscriptionURLProtocol.self]
        session = URLSession(configuration: options)
        SubscriptionURLProtocol.captured = nil
        SubscriptionURLProtocol.status = 200
        setReply(environment: "Sandbox")
    }

    override func tearDown() async throws { session.invalidateAndCancel() }

    func testVerifiedGuestPurchaseLinksWithoutFetchingUnavailableAppReceipt() async throws {
        var appReads = 0
        let service = service(appEnvironment: {
            appReads += 1
            throw SubscriptionAccountError.temporarilyUnavailable
        })
        let reply = try await service.sync(userID: owner, signedTransaction: "verified-purchase",
                                           purchaseEnvironment: .sandbox)
        XCTAssertEqual(appReads, 0)
        XCTAssertEqual(reply.userID, owner)
        let request = try XCTUnwrap(SubscriptionURLProtocol.captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Store-Environment"), "Sandbox")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    }

    func testProductionPurchaseKeepsItsVerifiedEnvironment() async throws {
        setReply(environment: "Production")
        let reply = try await service().sync(userID: owner, signedTransaction: "verified-production",
                                             purchaseEnvironment: .production)
        XCTAssertEqual(reply.environment, "Production")
        XCTAssertEqual(SubscriptionURLProtocol.captured?.value(forHTTPHeaderField: "X-Store-Environment"), "Production")
    }

    func testRecoveryWithoutPurchaseStillRequiresVerifiedAppEnvironment() async throws {
        var appReads = 0
        _ = try await service(appEnvironment: { appReads += 1; return .sandbox })
            .sync(userID: owner, signedTransaction: nil, purchaseEnvironment: .production)
        XCTAssertEqual(appReads, 1)
        XCTAssertEqual(SubscriptionURLProtocol.captured?.httpMethod, "GET")
        XCTAssertEqual(SubscriptionURLProtocol.captured?.value(forHTTPHeaderField: "X-Store-Environment"), "Sandbox")
    }

    func testUnavailableAppReceiptWithoutPurchaseCannotInventRecovery() async {
        await assertFailure(service(appEnvironment: { throw SubscriptionAccountError.temporarilyUnavailable }),
                            proof: nil, environment: nil)
        XCTAssertNil(SubscriptionURLProtocol.captured)
    }

    func testLocalXcodeProofNeverReachesAccountServer() async {
        await assertFailure(service(), proof: "local-fixture", environment: .xcode)
        XCTAssertNil(SubscriptionURLProtocol.captured)
    }

    func testWrongEnvironmentOrOwnerIsRejected() async {
        setReply(environment: "Production")
        await assertFailure(service(), proof: "verified-sandbox", environment: .sandbox)
        setReply(environment: "Sandbox", userID: UUID())
        await assertFailure(service(), proof: "verified-sandbox", environment: .sandbox)
    }

    func testOnlyTransientHTTPFailuresAreRetryable() async throws {
        for status in [401, 400, 409, 429, 503] {
            SubscriptionURLProtocol.status = status
            do {
                _ = try await service().sync(userID: owner, signedTransaction: "proof", purchaseEnvironment: .sandbox)
                XCTFail("Unexpected HTTP success")
            } catch let error as SubscriptionAccountError {
                if status == 429 || status == 503 {
                    guard case .temporarilyUnavailable = error else { XCTFail("Missing transient classification"); continue }
                } else {
                    guard case .unavailable = error else { XCTFail("Permanent failure would be retried"); continue }
                }
            }
        }
    }

    private func service(appEnvironment: @escaping () async throws -> AppStore.Environment = { .sandbox }) -> SupabaseSubscriptionService {
        SupabaseSubscriptionService(config: config, session: session, appEnvironment: appEnvironment,
                                    token: { _ in "fixture-token" })
    }

    private func assertFailure(_ service: SupabaseSubscriptionService, proof: String?, environment: AppStore.Environment?) async {
        do {
            _ = try await service.sync(userID: owner, signedTransaction: proof, purchaseEnvironment: environment)
            XCTFail("Unverified account recovery accepted")
        } catch { XCTAssertTrue(error is SubscriptionAccountError) }
    }

    private func setReply(environment: String, userID: UUID? = nil) {
        SubscriptionURLProtocol.data = try! JSONSerialization.data(withJSONObject: [
            "user_id": (userID ?? owner).uuidString, "environment": environment,
            "product_id": ProPlan.monthly.productID, "valid_until_ms": Date().addingTimeInterval(60).timeIntervalSince1970 * 1000,
            "link": "linked"])
    }
}

private final class SubscriptionURLProtocol: URLProtocol, @unchecked Sendable {
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
