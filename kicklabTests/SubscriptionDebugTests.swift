import XCTest
import StoreKit
@testable import kicklab

@MainActor
final class SubscriptionDebugTests: XCTestCase {
    func testSafeCodesKeepUnderlyingAppleFailureWithoutPrivateDescriptions() {
        let internalError = NSError(domain: "SKInternalErrorDomain", code: 12,
            userInfo: [NSLocalizedDescriptionKey: "private@example.test receipt=SECRET"])
        let wrapper = NSError(domain: "SKErrorDomain", code: 0,
            userInfo: [NSUnderlyingErrorKey: internalError, "account": "SECRET"])
        XCTAssertEqual(SubscriptionDebugError.describe(StoreKitError.systemError(wrapper)),
                       "StoreKit system error → SKErrorDomain / 0 → SKInternalErrorDomain / 12")
    }

    func testUnknownDomainsCannotLeakIdentifiers() {
        let error = NSError(domain: "private@example.test", code: 9,
                            userInfo: [NSLocalizedDescriptionKey: "SECRET"])
        XCTAssertEqual(SubscriptionDebugError.describe(error), "Other error domain / 9")
    }

    func testRestoreDiagnosticKeepsFailureAfterVerifiedAccessRefresh() async {
        let source = DebugEntitlementFixture(active: false)
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source,
            syncAppStore: {
                source.active = true
                throw NSError(domain: "SKInternalErrorDomain", code: 12)
            })
        _ = try? await store.restore()
        XCTAssertEqual(store.debugRestore, "SKInternalErrorDomain / 12 · Pro active")
        XCTAssertEqual(store.debugEnvironment, .sandbox)
        XCTAssertEqual(store.debugAccessSource, "Verified Apple transaction")
        XCTAssertEqual(store.debugAccountState, "Guest · account sync skipped")
        XCTAssertNotNil(store.debugRestoreTime)
        await store.refreshEntitlements()
        XCTAssertEqual(store.debugRestore, "SKInternalErrorDomain / 12 · Pro active")
    }

    func testSuccessfulSyncWithoutPurchaseDoesNotClaimPro() async throws {
        let store = SubscriptionStore(observeTransactions: false,
            entitlementSource: DebugEntitlementFixture(active: false), syncAppStore: {})
        let restored = try await store.restore()
        XCTAssertFalse(restored)
        XCTAssertEqual(store.debugRestore, "Apple sync succeeded · no active Pro")
        XCTAssertNil(store.debugEnvironment)
    }
}

@MainActor
private final class DebugEntitlementFixture: LocalSubscriptionEntitlementSource {
    var active: Bool
    init(active: Bool = true) { self.active = active }
    func current() async -> LocalSubscriptionEntitlement? {
        active ? LocalSubscriptionEntitlement(plan: .monthly, validUntil: Date().addingTimeInterval(60),
            signedTransaction: nil, environment: .sandbox) : nil
    }
}
