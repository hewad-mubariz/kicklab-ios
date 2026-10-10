import Combine
import Foundation
import StoreKit

/// StoreKit's signed on-device entitlement is the authority for this first iOS integration.
/// This never waits on Supabase or participates in capture / replay preparation.
@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var products: [ProPlan: Product] = [:]
    @Published private(set) var activePlan: ProPlan?
    @Published private(set) var hasCheckedAccess = false
    @Published private(set) var loading = false
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var catalogError: String?

    enum Operation { case idle, purchasing, restoring }
    enum PurchaseOutcome: Equatable { case purchased, cancelled, pending }
    var isPro: Bool { activePlan != nil }
    var busy: Bool { operation != .idle }
    private var updates: Task<Void, Never>?
    private var entitlementRefresh: Task<Void, Never>?
    private var refreshRequested = false

    init(observeTransactions: Bool = true) {
        guard observeTransactions else { return }
        // Listen immediately, including purchases completed after the paywall closes.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                await self?.receive(result)
            }
        }
    }

    deinit { updates?.cancel() }

    func loadProducts() async {
        guard !loading else { return }
        loading = true
        catalogError = nil
        defer { loading = false }
        do {
            let fetched = try await Product.products(for: ProPlan.allCases.map(\.productID))
            var available: [ProPlan: Product] = [:]
            for product in fetched {
                guard let plan = ProPlan(productID: product.id), plan.matches(product) else { continue }
                available[plan] = product
            }
            products = available
            if available.count != ProPlan.allCases.count {
                catalogError = "Some plans aren’t available right now. Please try again."
            }
        } catch {
            catalogError = "Plans couldn’t load. Check your connection and try again."
        }
    }

    func refreshEntitlements() async {
        refreshRequested = true
        if let entitlementRefresh {
            await entitlementRefresh.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.refreshRequested = false
                await self.readEntitlements()
            } while self.refreshRequested
        }
        entitlementRefresh = task
        await task.value
        entitlementRefresh = nil
    }

    private func readEntitlements() async {
        var current: [Transaction] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ProPlan(productID: transaction.productID) != nil,
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else { continue }
            // Includes Apple-authorized billing grace periods; do not filter by expiry here.
            current.append(transaction)
        }
        activePlan = current.max(by: { $0.purchaseDate < $1.purchaseDate })
            .flatMap { ProPlan(productID: $0.productID) }
        hasCheckedAccess = true
    }

    func purchase(_ plan: ProPlan, accountID: UUID?) async throws -> PurchaseOutcome {
        guard !busy else { throw SubscriptionFailure.busy }
        guard let product = products[plan] else { throw SubscriptionFailure.unavailable }
        operation = .purchasing
        defer { operation = .idle }
        var options: Set<Product.PurchaseOption> = []
        if let accountID { options.insert(.appAccountToken(accountID)) }
        switch try await product.purchase(options: options) {
        case .success(let result):
            guard case .verified(let transaction) = result,
                  ProPlan(productID: transaction.productID) != nil else {
                throw SubscriptionFailure.unverified
            }
            await refreshEntitlements()
            deliverVerifiedPurchase(transaction)
            await transaction.finish()
            guard isPro else { throw SubscriptionFailure.activation }
            return .purchased
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: throw SubscriptionFailure.unavailable
        }
    }

    /// AppStore.sync may show an account prompt, so call only from an explicit Restore tap.
    func restore() async throws -> Bool {
        guard !busy else { throw SubscriptionFailure.busy }
        operation = .restoring
        defer { operation = .idle }
        try await AppStore.sync()
        await refreshEntitlements()
        return isPro
    }

    private func receive(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result,
              ProPlan(productID: transaction.productID) != nil else { return }
        await refreshEntitlements()
        deliverVerifiedPurchase(transaction)
        await transaction.finish()
    }

    private func deliverVerifiedPurchase(_ transaction: Transaction) {
        // Apple can return a verified purchase before its history snapshot catches up.
        // Deliver from that signed transaction immediately, without waiting on a server.
        // Foreground / restore still rebuild access exclusively from current entitlements.
        guard activePlan == nil, transaction.revocationDate == nil, !transaction.isUpgraded,
              let expiry = transaction.expirationDate, expiry > Date(),
              let plan = ProPlan(productID: transaction.productID) else { return }
        activePlan = plan
        hasCheckedAccess = true
    }

    func offer(for plan: ProPlan) -> ProOffer? {
        guard let product = products[plan] else { return nil }
        return ProOffer(plan: plan, product: product, monthly: products[.monthly])
    }
}

nonisolated enum SubscriptionFailure: LocalizedError {
    case unavailable, unverified, busy, activation
    var errorDescription: String? {
        switch self {
        case .unavailable: "This plan isn’t available right now. Please try again."
        case .unverified: "Apple couldn’t verify this purchase. Try Restore purchases, or contact Apple Support if the charge appears in your purchase history."
        case .activation: "Apple confirmed the transaction, but an active subscription isn’t available yet. Please try Restore purchases."
        case .busy: "A purchase or restore is already in progress."
        }
    }
}
