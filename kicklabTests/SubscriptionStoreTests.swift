import XCTest
import StoreKit
import StoreKitTest
@testable import kicklab

@MainActor
final class SubscriptionStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var store: SubscriptionStore!

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "JuggleDude", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.timeRate = .realTime
        session.disableDialogs = true
        session.storefront = "DEU"
        session.locale = Locale(identifier: "en_US")
        store = SubscriptionStore()
        await store.refreshEntitlements()
        await store.loadProducts()
    }

    override func tearDown() async throws {
        store = nil
        session?.clearTransactions()
        session?.resetToDefaultState()
        session = nil
    }

    func testAppStorePricesPeriodsAndSaving() throws {
        XCTAssertEqual(store.products.count, 2)
        XCTAssertNil(store.catalogError)
        XCTAssertEqual(store.products[.monthly]?.price, Decimal(string: "4.99"))
        XCTAssertEqual(store.products[.yearly]?.price, Decimal(string: "29.99"))
        let yearly = try XCTUnwrap(store.offer(for: .yearly))
        XCTAssertEqual(yearly.badge, "Save 50%")
        XCTAssertTrue(yearly.perMonth?.contains("2.50") == true)
        XCTAssertFalse(store.isPro)
        XCTAssertTrue(store.hasCheckedAccess)
    }

    func testPurchaseDeliversVerifiedAccessAndAccountToken() async throws {
        let account = UUID()
        let outcome = try await store.purchase(.monthly, accountID: account)
        XCTAssertEqual(outcome, .purchased)
        XCTAssertEqual(store.activePlan, .monthly)
        XCTAssertFalse(store.busy)
        try await waitForStoreKitHistory(.monthly)
        var found = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            XCTAssertEqual(transaction.appAccountToken, account)
            found = true
        }
        XCTAssertTrue(found)
    }

    func testRelaunchAndRestoreRecoverYearlySubscription() async throws {
        _ = try await store.purchase(.yearly, accountID: nil)
        try await waitForStoreKitHistory(.yearly)
        let restarted = SubscriptionStore(observeTransactions: false)
        await restarted.refreshEntitlements()
        XCTAssertEqual(restarted.activePlan, .yearly)
        let restored = try await restarted.restore()
        XCTAssertTrue(restored)
    }

    func testRestoreSkipsAppleSyncWhenAlreadyActive() async throws {
        _ = try await store.purchase(.monthly, accountID: nil)
        try await waitForStoreKitHistory(.monthly)
        var syncs = 0
        let restarted = SubscriptionStore(observeTransactions: false, syncAppStore: { syncs += 1 })
        let restored = try await restarted.restore()
        XCTAssertTrue(restored)
        XCTAssertEqual(syncs, 0, "An active subscription must not trigger the Apple Account prompt")
    }

    func testNoPurchasesRestoresAsFree() async throws {
        let restored = try await store.restore()
        XCTAssertFalse(restored)
        XCTAssertFalse(store.busy)
    }

    func testAccountRecoveryUnlocksStoreAndSignOutClearsAccountOnlyAccess() async throws {
        let id = UUID()
        let service = LinkedAccountFixture(owner: id)
        let recovered = SubscriptionStore(observeTransactions: false, accountService: service)
        await recovered.useAccount(id)
        try await eventually { recovered.isPro && !recovered.checkingAccountAccess }
        XCTAssertTrue(recovered.isAccountOnlyPro)
        XCTAssertEqual(recovered.activePlan, .yearly)
        await recovered.useAccount(nil)
        XCTAssertFalse(recovered.isPro)
        XCTAssertFalse(recovered.isAccountOnlyPro)
    }

    func testLateRenewalIsPickedUpAfterThePeriodEnds() async throws {
        // The first period ends, Apple briefly reports nothing, then the renewal appears.
        let source = LateRenewalSource(firstEnd: Date().addingTimeInterval(0.4))
        let renewing = SubscriptionStore(observeTransactions: false, entitlementSource: source,
                                         renewalRecheckDelays: [.milliseconds(300), .milliseconds(300)])
        await renewing.refreshEntitlements()
        XCTAssertEqual(renewing.activePlan, .monthly)
        try await eventually { !renewing.isPro }
        source.renewed = true
        try await eventually { renewing.isPro }
        XCTAssertEqual(renewing.activePlan, .monthly)
    }

    func testPurchaseLinkedElsewhereHidesRetry() async throws {
        let id = UUID()
        let store = SubscriptionStore(observeTransactions: false, accountService: ElsewhereAccountFixture())
        await store.useAccount(id)
        try await eventually { store.accountLinkMessage != nil && !store.checkingAccountAccess }
        XCTAssertTrue(store.accountLinkedElsewhere, "Retry cannot fix a purchase owned by another account")
        await store.useAccount(nil)
        XCTAssertFalse(store.accountLinkedElsewhere)
    }

    func testLocalTestingEnvironmentSkipsAccountSyncWithoutError() async throws {
        let id = UUID()
        let recovered = SubscriptionStore(observeTransactions: false, accountService: LocalTestingAccountFixture())
        await recovered.useAccount(id)
        try await eventually { !recovered.checkingAccountAccess }
        XCTAssertNil(recovered.accountLinkMessage, "Local StoreKit testing must not show an unfixable sync error")
        XCTAssertFalse(recovered.isAccountOnlyPro)
    }

    func testLocalGuestPurchaseSurvivesFailedAccountSyncAndSignOut() async throws {
        _ = try await store.purchase(.monthly, accountID: nil)
        try await waitForStoreKitHistory(.monthly)
        let id = UUID(), service = LinkedAccountFixture(owner: UUID())
        let recovered = SubscriptionStore(observeTransactions: false, accountService: service)
        await recovered.useAccount(id)
        try await eventually { recovered.accountLinkMessage != nil }
        XCTAssertFalse(recovered.accountLinkedElsewhere, "A failed sync keeps Retry available")
        XCTAssertEqual(recovered.activePlan, .monthly)
        XCTAssertFalse(recovered.isAccountOnlyPro)
        await recovered.useAccount(nil)
        XCTAssertEqual(recovered.activePlan, .monthly)
        XCTAssertNil(recovered.accountLinkMessage)
        XCTAssertFalse(recovered.accountLinkedElsewhere)
    }

    func testRefundRemovesAccessThroughTransactionListener() async throws {
        _ = try await store.purchase(.monthly, accountID: nil)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.refundTransaction(identifier: transaction.identifier)
        try await eventually { !self.store.isPro }
    }

    func testExpirationRemovesAccessOnForegroundRefresh() async throws {
        _ = try await store.purchase(.monthly, accountID: nil)
        try session.expireSubscription(productIdentifier: ProPlan.monthly.productID)
        await store.refreshEntitlements()
        XCTAssertFalse(store.isPro)
    }

    func testAskToBuyWaitsForApprovalThenDeliversAutomatically() async throws {
        session.askToBuyEnabled = true
        let outcome = try await store.purchase(.monthly, accountID: nil)
        XCTAssertEqual(outcome, .pending)
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.busy)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        try await eventually { self.store.isPro }
    }

    func testUnverifiedPurchaseNeverGrantsAccess() async throws {
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        do {
            _ = try await store.purchase(.monthly, accountID: nil)
            XCTFail("An unverified transaction must not deliver Pro")
        } catch { XCTAssertTrue(error is SubscriptionFailure) }
        await store.refreshEntitlements()
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.busy)
    }

    func testLoadFailureCanBeRetried() async throws {
        let newStore = SubscriptionStore(observeTransactions: false)
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await newStore.loadProducts()
        XCTAssertNotNil(newStore.catalogError)
        XCTAssertTrue(newStore.products.isEmpty)
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        await newStore.loadProducts()
        XCTAssertEqual(newStore.products.count, 2)
        XCTAssertNil(newStore.catalogError)
    }

    func testCancelledPurchaseKeepsFreeAccessAndAllowsRetry() async throws {
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        do {
            let outcome = try await store.purchase(.monthly, accountID: nil)
            XCTAssertEqual(outcome, .cancelled)
        } catch {
            guard let error = error as? StoreKitError, case .userCancelled = error else {
                XCTFail("Expected Apple cancellation"); return
            }
        }
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.busy)
    }

    func testRestoreFailureDoesNotGrantAccess() async throws {
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
        do {
            _ = try await store.restore()
            XCTFail("Restore should report the network failure")
        } catch { }
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.busy)
    }

    func testSavingsNotAdvertisedForInvalidOrMoreExpensiveAnnualPlans() {
        XCTAssertNil(ProOffer.savingPercent(monthly: 0, yearly: 29))
        XCTAssertNil(ProOffer.savingPercent(monthly: 4, yearly: 49))
        XCTAssertNil(ProOffer.savingPercent(monthly: 4, yearly: -1))
    }

    /// SKTestSession publishes its history asynchronously after the verified purchase result.
    private func waitForStoreKitHistory(_ plan: ProPlan) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, transaction.productID == plan.productID { return }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("StoreKit did not publish the verified subscription in its history")
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private struct LinkedAccountFixture: SubscriptionAccountService {
    let owner: UUID
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        guard userID == owner else { throw SubscriptionAccountError.unavailable }
        return SubscriptionAccountReply(userID: owner, productID: ProPlan.yearly.productID,
            validUntilMS: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            environment: "Production", link: "linked")
    }
}

private struct LocalTestingAccountFixture: SubscriptionAccountService {
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        throw SubscriptionAccountError.localTestingOnly
    }
}

@MainActor
private final class LateRenewalSource: LocalSubscriptionEntitlementSource {
    let firstEnd: Date
    var renewed = false
    init(firstEnd: Date) { self.firstEnd = firstEnd }
    func current() async -> LocalSubscriptionEntitlement? {
        if renewed { return LocalSubscriptionEntitlement(plan: .monthly, validUntil: Date().addingTimeInterval(180), signedTransaction: nil) }
        return firstEnd > Date() ? LocalSubscriptionEntitlement(plan: .monthly, validUntil: firstEnd, signedTransaction: nil) : nil
    }
}

private struct ElsewhereAccountFixture: SubscriptionAccountService {
    func sync(userID: UUID, signedTransaction: String?, purchaseEnvironment: AppStore.Environment?) async throws -> SubscriptionAccountReply {
        SubscriptionAccountReply(userID: userID, productID: nil, validUntilMS: nil, environment: nil, link: "another_account")
    }
}
