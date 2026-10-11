import XCTest
import StoreKit
@testable import kicklab

@MainActor
final class LocalSubscriptionExpiryTests: XCTestCase {
    func testExpiredCachedPurchaseCannotUnlockFreshLaunch() async {
        let source = EntitlementFixture(until: Date().addingTimeInterval(-10))
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source)
        await store.refreshEntitlements()
        XCTAssertFalse(store.isPro)
        XCTAssertNil(store.localAccessUntil)
        XCTAssertTrue(store.hasCheckedAccess)
    }

    func testLocalAccessExpiresWhileAppStaysOpenEvenWhenSourceIsStale() async throws {
        let source = EntitlementFixture(until: Date().addingTimeInterval(0.15))
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source)
        await store.refreshEntitlements()
        XCTAssertTrue(store.isPro)
        try await eventually { !store.isPro && source.reads > 1 }
        XCTAssertNil(store.localAccessUntil)
    }

    func testExpiryRefreshPicksUpRenewalWithoutReopeningApp() async throws {
        let source = EntitlementFixture(until: Date().addingTimeInterval(0.15))
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source)
        await store.refreshEntitlements()
        let renewedEnd = Date().addingTimeInterval(60)
        source.end = renewedEnd
        try await eventually { source.reads > 1 && store.localAccessUntil == renewedEnd }
        XCTAssertTrue(store.isPro)
    }

    func testReplacedExpiryTimerCannotRevokeNewPeriod() async throws {
        let source = EntitlementFixture(until: Date().addingTimeInterval(0.15))
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source)
        await store.refreshEntitlements()
        source.end = Date().addingTimeInterval(60)
        await store.refreshEntitlements()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.localAccessUntil, source.end)
        XCTAssertEqual(source.reads, 2)
    }

    func testExpiredLocalPurchaseDoesNotRemoveValidAccountRecovery() async throws {
        let id = UUID(), source = EntitlementFixture(until: Date().addingTimeInterval(-10))
        let store = SubscriptionStore(observeTransactions: false, accountService: ActiveAccountFixture(),
                                      entitlementSource: source)
        await store.useAccount(id)
        try await eventually { store.isAccountOnlyPro }
        XCTAssertTrue(store.isPro)
        XCTAssertNil(store.localAccessUntil)
        await store.useAccount(nil)
        XCTAssertFalse(store.isPro)
    }

    func testExpiredCachedDatesRequireVerifiedFutureGrace() {
        let now = Date(), expired = now.addingTimeInterval(-10), grace = now.addingTimeInterval(100)
        XCTAssertNil(LocalSubscriptionAccess.validUntil(expiration: expired, verifiedGraceEnd: nil, now: now))
        XCTAssertNil(LocalSubscriptionAccess.validUntil(expiration: expired, verifiedGraceEnd: now, now: now))
        XCTAssertEqual(LocalSubscriptionAccess.validUntil(expiration: expired, verifiedGraceEnd: grace, now: now), grace)
        XCTAssertEqual(LocalSubscriptionAccess.validUntil(expiration: grace, verifiedGraceEnd: nil, now: now), grace)
    }

    func testReleaseAcceptsAppleEnvironmentsButNeverLocalXcodePurchases() {
        XCTAssertTrue(LocalSubscriptionAccess.allows(.sandbox, localTesting: false))
        XCTAssertTrue(LocalSubscriptionAccess.allows(.production, localTesting: false))
        XCTAssertFalse(LocalSubscriptionAccess.allows(.xcode, localTesting: false))
        XCTAssertTrue(LocalSubscriptionAccess.allows(.xcode, localTesting: true))
    }

    func testFailedAppleRestoreStillRecoversVerifiedLocalAccessAndReportsFailure() async {
        let source = EntitlementFixture(until: Date().addingTimeInterval(-1))
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source,
                                      syncAppStore: {
            source.end = Date().addingTimeInterval(60)
            throw RestoreFixtureError.accountMissing
        })
        await assertRestoreFailure(store)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.activePlan, .monthly)
        XCTAssertEqual(store.localAccessUntil, source.end)
        XCTAssertFalse(store.busy)
    }

    func testFailedAppleRestoreCannotKeepAnExpiredLocalPurchaseActive() async {
        let source = EntitlementFixture(until: Date().addingTimeInterval(60))
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source,
                                      syncAppStore: { throw RestoreFixtureError.accountMissing })
        await store.refreshEntitlements()
        XCTAssertTrue(store.isPro)
        source.end = Date().addingTimeInterval(-1)
        await assertRestoreFailure(store)
        XCTAssertFalse(store.isPro)
        XCTAssertNil(store.localAccessUntil)
    }

    func testFailedAppleRestoreStillRetriesAccountRecovery() async throws {
        let source = EntitlementFixture(until: Date().addingTimeInterval(-1))
        let account = RecoveringAccountFixture()
        let store = SubscriptionStore(observeTransactions: false, accountService: account,
                                      entitlementSource: source,
                                      syncAppStore: {
            account.available = true
            throw RestoreFixtureError.accountMissing
        })
        await store.useAccount(UUID())
        try await eventually { store.accountLinkMessage != nil }
        XCTAssertFalse(store.isPro)
        await assertRestoreFailure(store)
        XCTAssertTrue(store.isAccountOnlyPro)
        XCTAssertEqual(store.activePlan, .yearly)
        XCTAssertNil(store.accountLinkMessage)
    }

    func testRestoreReturnsVerifiedLocalAccessWithoutPromptingApple() async throws {
        let source = EntitlementFixture(until: Date().addingTimeInterval(60))
        var syncs = 0
        let store = SubscriptionStore(observeTransactions: false, entitlementSource: source,
                                      syncAppStore: { syncs += 1 })
        let restored = try await store.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(store.activePlan, .monthly)
        XCTAssertEqual(syncs, 0)
        XCTAssertFalse(store.busy)
    }

    func testRestoreRecoversAccountAccessWithoutPromptingApple() async throws {
        let account = RecoveringAccountFixture()
        var syncs = 0
        let store = SubscriptionStore(observeTransactions: false, accountService: account,
            entitlementSource: EntitlementFixture(until: Date().addingTimeInterval(-1)),
            syncAppStore: { syncs += 1 })
        await store.useAccount(UUID())
        try await eventually { store.accountLinkMessage != nil }
        account.available = true
        let restored = try await store.restore()
        XCTAssertTrue(restored)
        XCTAssertTrue(store.isAccountOnlyPro)
        XCTAssertEqual(syncs, 0)
        XCTAssertFalse(store.busy)
    }

    func testRestoreWithoutAccessMustSyncAppleAndRemainFreeForEmptyHistory() async throws {
        var syncs = 0
        let store = SubscriptionStore(observeTransactions: false,
            entitlementSource: EntitlementFixture(until: Date().addingTimeInterval(-1)),
            syncAppStore: { syncs += 1 })
        let restored = try await store.restore()
        XCTAssertFalse(restored)
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(syncs, 1)
        XCTAssertFalse(store.busy)
    }

    func testGuestPurchaseSignInForwardsVerifiedProofAndEnvironment() async throws {
        let account = DelayedAccountFixture()
        let source = EntitlementFixture(until: Date().addingTimeInterval(60))
        source.proof = "verified-guest-purchase"; source.environment = .sandbox
        let store = SubscriptionStore(observeTransactions: false, accountService: account,
                                      entitlementSource: source)
        await store.refreshEntitlements()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(account.calls, 0)
        await store.useAccount(UUID())
        try await eventually { account.continuation != nil }
        XCTAssertEqual(account.proof, source.proof)
        XCTAssertEqual(account.environment, .sandbox)
        XCTAssertTrue(store.checkingAccountAccess)
        XCTAssertTrue(store.isPro)
        account.complete()
        try await eventually { !store.checkingAccountAccess }
        XCTAssertNil(store.accountLinkMessage)
    }

    func testManualAccountRetryWaitsForReplyAndKeepsLocalPro() async throws {
        let account = DelayedAccountFixture()
        account.fail = true
        let source = EntitlementFixture(until: Date().addingTimeInterval(60))
        source.proof = "verified-purchase"; source.environment = .sandbox
        let store = SubscriptionStore(observeTransactions: false, accountService: account,
                                      entitlementSource: source)
        await store.useAccount(UUID())
        try await eventually { store.accountLinkMessage != nil }
        account.fail = false
        var completed = false
        let retry = Task { await store.retryAccountSync(); completed = true }
        try await eventually { account.continuation != nil }
        XCTAssertFalse(completed)
        XCTAssertTrue(store.checkingAccountAccess)
        XCTAssertNil(store.accountLinkMessage)
        XCTAssertTrue(store.isPro)
        // A foreground refresh must join the retry, not cancel/restart it.
        await store.refreshEntitlements()
        account.complete()
        await retry.value
        XCTAssertTrue(completed)
        XCTAssertEqual(account.calls, 2)
        XCTAssertFalse(store.checkingAccountAccess)
        XCTAssertNil(store.accountLinkMessage)
        XCTAssertTrue(store.isPro)
    }

    private func assertRestoreFailure(_ store: SubscriptionStore) async {
        do {
            _ = try await store.restore()
            XCTFail("An Apple refresh failure must not be reported as a completed restore")
        } catch {
            XCTAssertEqual(error as? RestoreFixtureError, .accountMissing)
        }
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
}

private enum RestoreFixtureError: Error, Equatable { case accountMissing }

@MainActor
private final class RecoveringAccountFixture: SubscriptionAccountService {
    var available = false
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        guard available else { throw SubscriptionAccountError.unavailable }
        return try await ActiveAccountFixture().sync(userID: userID, signedTransaction: signedTransaction, purchaseEnvironment: purchaseEnvironment)
    }
}

@MainActor
private final class EntitlementFixture: LocalSubscriptionEntitlementSource {
    var end: Date
    var reads = 0
    var proof: String?
    var environment: AppStore.Environment?
    init(until: Date) { end = until }
    func current() async -> LocalSubscriptionEntitlement? {
        reads += 1
        return LocalSubscriptionEntitlement(plan: .monthly, validUntil: end,
                                            signedTransaction: proof, environment: environment)
    }
}

@MainActor
private final class DelayedAccountFixture: SubscriptionAccountService {
    var fail = false
    var calls = 0
    var proof: String?
    var environment: AppStore.Environment?
    var owner: UUID?
    var continuation: CheckedContinuation<SubscriptionAccountReply, Never>?
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        calls += 1; owner = userID; proof = signedTransaction; environment = purchaseEnvironment
        if fail { throw SubscriptionAccountError.unavailable }
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete() {
        guard let owner, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: SubscriptionAccountReply(userID: owner,
            productID: ProPlan.monthly.productID,
            validUntilMS: Date().addingTimeInterval(60).timeIntervalSince1970 * 1000,
            environment: "Sandbox", link: "linked"))
    }
}

@MainActor
private struct ActiveAccountFixture: SubscriptionAccountService {
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        SubscriptionAccountReply(userID: userID, productID: ProPlan.yearly.productID,
            validUntilMS: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            environment: "Sandbox", link: "linked")
    }
}
