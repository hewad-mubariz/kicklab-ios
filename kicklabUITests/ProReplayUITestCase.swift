import XCTest
import StoreKitTest

/// Visual regressions for the paid editor use verified local StoreKit purchases.
/// Run with JuggleDude-StoreKit on a runtime that supports SKTestSession.
@MainActor
class ProReplayUITestCase: XCTestCase {
    private var subscription: SKTestSession?

    override func setUp() async throws {
        try await super.setUp()
        let session = try SKTestSession(contentsOf: XCTUnwrap(Bundle(for: ProReplayUITestCase.self)
            .url(forResource: "JuggleDude", withExtension: "storekit")))
        subscription = session
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        _ = try await session.buyProduct(identifier: "com.hewad.juggledude.pro.monthly")
    }

    override func tearDown() async throws {
        subscription?.clearTransactions()
        subscription?.resetToDefaultState()
        subscription = nil
        try await super.tearDown()
    }
}
