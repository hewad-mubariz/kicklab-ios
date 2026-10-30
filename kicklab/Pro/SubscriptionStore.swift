import Combine
import Foundation
import StoreKit

/// Verified local StoreKit purchases and verified account access both unlock Pro.
/// Account syncing never delays delivery of a local purchase or camera/replay work.
@MainActor
final class SubscriptionStore: ObservableObject {
    /// This separate local app is for unrestricted feature testing, without purchases.
    #if DEBUG && TOUCH_COUNTING_DEBUG
    static let isFreeDebugBuild = true
    #else
    static let isFreeDebugBuild = false
    #endif
    @Published private(set) var products: [ProPlan: Product] = [:]
    @Published private(set) var activePlan: ProPlan?
    @Published private(set) var hasCheckedAccess = false
    @Published private(set) var loading = false
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var catalogError: String?
    @Published private(set) var accountLinkMessage: String?
    @Published private(set) var checkingAccountAccess = false
    @Published private(set) var accountLinkedElsewhere = false
    @Published private(set) var localAccessUntil: Date?
    #if DEBUG
    @Published private(set) var debugEnvironment: AppStore.Environment?
    @Published private(set) var debugRestore = "Not attempted in this launch"
    @Published private(set) var debugRestoreTime: Date?
    @Published private(set) var debugAppTransaction = "Not checked"
    var debugAccessSource: String {
        if Self.isFreeDebugBuild { return "Free debug build" }
        return localPlan != nil ? "Verified Apple transaction" : isAccountOnlyPro ? "Verified account recovery" : "No active access"
    }
    var debugAccountState: String {
        guard accountLink.userID != nil else { return "Guest · account sync skipped" }
        if checkingAccountAccess { return "Syncing account…" }
        if accountLinkMessage != nil { return "Account sync needs attention" }
        return accountLink.plan != nil ? "Account access verified" : "Signed in · no account grant"
    }

    func checkDebugAppTransaction() async {
        debugAppTransaction = "Checking…"
        defer { saveDebugSnapshot() }
        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                debugAppTransaction = "Verified · \(SubscriptionDebugError.environment(transaction.environment))"
            case .unverified: debugAppTransaction = "Unverified"
            }
        } catch { debugAppTransaction = SubscriptionDebugError.describe(error) }
    }

    private func saveDebugSnapshot() {
        let info = Bundle.main.infoDictionary ?? [:]
        let report: [String: String] = [
            "revision": "D1", "configuration": "Local Debug",
            "version": info["CFBundleShortVersionString"] as? String ?? "?",
            "build": info["CFBundleVersion"] as? String ?? "?",
            "saved_at": Date().ISO8601Format(),
            "plan": activePlan?.rawValue ?? "free", "source": debugAccessSource,
            "purchase_environment": SubscriptionDebugError.environment(debugEnvironment),
            "apple_expiry": localAccessUntil?.ISO8601Format() ?? "none",
            "account": debugAccountState, "app_transaction": debugAppTransaction,
            "last_restore_at": debugRestoreTime?.ISO8601Format() ?? "none",
            "last_restore": debugRestore
        ]
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SubscriptionDebug", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("latest.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch { /* Debug export must never affect subscription operations. */ }
    }
    #endif
    private let accountLink: SubscriptionAccountLink
    private let entitlementSource: any LocalSubscriptionEntitlementSource
    private let syncAppStore: @MainActor () async throws -> Void
    private var accountObservation: AnyCancellable?
    private var messageObservation: AnyCancellable?
    private var checkingObservation: AnyCancellable?
    private var elsewhereObservation: AnyCancellable?
    private var localPlan: ProPlan?
    private var localProof: String?
    private var localEnvironment: AppStore.Environment?
    private var accountSync: Task<Void, Never>?
    var isAccountOnlyPro: Bool { localPlan == nil && accountLink.plan != nil }

    enum Operation { case idle, purchasing, restoring }
    enum PurchaseOutcome: Equatable { case purchased, cancelled, pending }
    var isPro: Bool { Self.isFreeDebugBuild || activePlan != nil }
    var busy: Bool { operation != .idle }
    private var updates: Task<Void, Never>?
    private var entitlementRefresh: Task<Void, Never>?
    private var refreshRequested = false
    private var localExpiry: Task<Void, Never>?
    private var localGeneration = UUID()
    private var renewalCheck: Task<Void, Never>?
    /// Apple can publish a renewal shortly after the old period ends (the sandbox renews
    /// at the boundary), so a lapse is rechecked a few times before settling on Free.
    private let renewalRecheckDelays: [Duration]

    init(observeTransactions: Bool = true, accountService: (any SubscriptionAccountService)? = nil,
         entitlementSource: (any LocalSubscriptionEntitlementSource)? = nil,
         syncAppStore: @escaping @MainActor () async throws -> Void = { try await AppStore.sync() },
         renewalRecheckDelays: [Duration] = [.seconds(10), .seconds(20), .seconds(30)]) {
        self.renewalRecheckDelays = renewalRecheckDelays
        self.entitlementSource = entitlementSource ?? StoreKitEntitlementSource()
        self.syncAppStore = syncAppStore
        accountLink = SubscriptionAccountLink(service: accountService)
        if Self.isFreeDebugBuild {
            hasCheckedAccess = true
            return
        }
        accountObservation = accountLink.$plan.sink { [weak self] plan in
            guard let self else { return }
            self.activePlan = self.localPlan ?? plan
        }
        messageObservation = accountLink.$message.sink { [weak self] in self?.accountLinkMessage = $0 }
        checkingObservation = accountLink.$isChecking.sink { [weak self] in self?.checkingAccountAccess = $0 }
        elsewhereObservation = accountLink.$linkedElsewhere.sink { [weak self] in self?.accountLinkedElsewhere = $0 }
        guard observeTransactions else { return }
        // Listen immediately, including purchases completed after the paywall closes.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                await self?.receive(result)
            }
        }
    }

    deinit { updates?.cancel(); accountSync?.cancel(); localExpiry?.cancel(); renewalCheck?.cancel() }

    static func live(account: AccountStore) -> SubscriptionStore {
        if isFreeDebugBuild { return SubscriptionStore(observeTransactions: false) }
        guard let config = try? AccountConfiguration.load() else { return SubscriptionStore() }
        return SubscriptionStore(accountService: SupabaseSubscriptionService(config: config) { [weak account] id in
            guard let account else { throw SubscriptionAccountError.unavailable }
            return try await account.accessToken(for: id)
        })
    }

    func useAccount(_ id: UUID?) async {
        guard !Self.isFreeDebugBuild else { return }
        accountSync?.cancel()
        accountLink.useAccount(id)
        await refreshEntitlements()
        #if DEBUG
        saveDebugSnapshot()
        #endif
    }

    private func syncAccount() {
        accountSync?.cancel()
        let proof = localProof
        let environment = localEnvironment
        accountSync = Task { [weak self] in
            await self?.accountLink.refresh(signedTransaction: proof, purchaseEnvironment: environment)
        }
    }

    func retryAccountSync() async {
        await refreshEntitlements()
        await accountSync?.value
    }

    func loadProducts() async {
        guard !Self.isFreeDebugBuild else { return }
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
                catalogError = String(localized: "Some plans aren’t available right now. Please try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            }
        } catch {
            catalogError = String(localized: "Plans couldn’t load. Check your connection and try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }

    func refreshEntitlements() async {
        guard !Self.isFreeDebugBuild else { return }
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
        setLocalEntitlement(await entitlementSource.current())
        hasCheckedAccess = true
        syncAccount()
    }

    private func setLocalEntitlement(_ entitlement: LocalSubscriptionEntitlement?) {
        localExpiry?.cancel(); localExpiry = nil
        localGeneration = UUID()
        let valid = entitlement.flatMap { $0.validUntil > Date() ? $0 : nil }
        localPlan = valid?.plan; localProof = valid?.signedTransaction
        localEnvironment = valid?.environment
        localAccessUntil = valid?.validUntil
        #if DEBUG
        debugEnvironment = valid?.environment
        #endif
        activePlan = localPlan ?? accountLink.plan
        guard let end = valid?.validUntil else { return }
        let generation = localGeneration
        localExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled, self.localGeneration == generation else { return }
            self.localExpiry = nil
            self.setLocalEntitlement(nil)
            // Pick up renewal or grace without requiring a foreground transition.
            await self.refreshEntitlements()
            self.recheckForLateRenewal()
        }
    }

    /// After a period ends with no renewal visible yet, ask Apple again a few times
    /// (10 s, 30 s and 60 s after the lapse by default). Stops as soon as access returns.
    private func recheckForLateRenewal() {
        renewalCheck?.cancel(); renewalCheck = nil
        guard localPlan == nil, !renewalRecheckDelays.isEmpty else { return }
        let delays = renewalRecheckDelays
        renewalCheck = Task { [weak self] in
            for delay in delays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled, self.localPlan == nil else { return }
                await self.refreshEntitlements()
            }
        }
    }

    func purchase(_ plan: ProPlan, accountID: UUID?) async throws -> PurchaseOutcome {
        guard !Self.isFreeDebugBuild else { throw SubscriptionFailure.unavailable }
        guard !busy, !checkingAccountAccess else { throw SubscriptionFailure.busy }
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
            if Self.canLinkToAccount(transaction) {
                localProof = result.jwsRepresentation; localEnvironment = transaction.environment; syncAccount()
            }
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
        if Self.isFreeDebugBuild { return true }
        guard !busy else { throw SubscriptionFailure.busy }
        operation = .restoring
        defer { operation = .idle }
        #if DEBUG
        debugRestoreTime = Date()
        debugRestore = "Waiting for Apple…"
        #endif
        // Check quietly first. If Apple already reports an active subscription there is
        // nothing to restore, so skip AppStore.sync and its Apple Account password prompt.
        await refreshEntitlements()
        await accountSync?.value
        if isPro {
            #if DEBUG
            debugRestore = "Already active · no Apple sync needed · Pro active"
            saveDebugSnapshot()
            #endif
            return true
        }
        var syncFailure: Error?
        do { try await syncAppStore() }
        catch { syncFailure = error }
        #if DEBUG
        let appleResult = syncFailure.map { SubscriptionDebugError.describe($0) } ?? "Apple sync succeeded"
        debugRestore = appleResult + " · checking access…"
        defer {
            debugRestore = appleResult + (isPro ? " · Pro active" : " · no active Pro")
            saveDebugSnapshot()
        }
        #endif
        // Apple's interactive refresh can fail independently of verified local
        // access or account recovery. Recheck both, while still reporting the
        // failed refresh rather than claiming that Restore completed.
        try Task.checkCancellation()
        await refreshEntitlements()
        await accountSync?.value
        if let syncFailure { throw syncFailure }
        return isPro
    }

    /// Modern offer-code sheets return their transaction directly. Reuse the same
    /// verification, account linking and finishing path as transaction updates.
    func receiveOfferCode(_ result: VerificationResult<Transaction>) async throws {
        guard case .verified(let transaction) = result,
              transaction.productType == .autoRenewable,
              ProPlan(productID: transaction.productID) != nil else {
            throw SubscriptionFailure.unverified
        }
        await receive(result)
    }

    private func receive(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result,
              ProPlan(productID: transaction.productID) != nil else { return }
        await refreshEntitlements()
        deliverVerifiedPurchase(transaction)
        // Updates also report refunds, upgrades and lapsed periods. Only a currently
        // active purchase can be linked; anything else would be rejected by the server
        // and surface as a sync error. The account refresh above already ran without it.
        if Self.canLinkToAccount(transaction) {
            localProof = result.jwsRepresentation; localEnvironment = transaction.environment; syncAccount()
        }
        await transaction.finish()
    }

    /// A purchase the account server will accept as proof: a real Apple environment,
    /// not revoked or upgraded, and still inside its paid period.
    static func canLinkToAccount(_ transaction: Transaction, now: Date = Date()) -> Bool {
        (transaction.environment == .production || transaction.environment == .sandbox)
            && transaction.revocationDate == nil && !transaction.isUpgraded
            && (transaction.expirationDate.map { $0 > now } ?? false)
    }

    private func deliverVerifiedPurchase(_ transaction: Transaction) {
        // Apple can return a verified purchase before its history snapshot catches up.
        // Deliver from that signed transaction immediately, without waiting on a server.
        // Foreground / restore still rebuild access exclusively from current entitlements.
        guard localPlan == nil, transaction.revocationDate == nil, !transaction.isUpgraded,
              transaction.productType == .autoRenewable,
              LocalSubscriptionAccess.allows(transaction.environment,
                  localTesting: LocalSubscriptionAccess.allowsLocalTesting),
              let expiry = transaction.expirationDate, expiry > Date(),
              let plan = ProPlan(productID: transaction.productID) else { return }
        setLocalEntitlement(LocalSubscriptionEntitlement(plan: plan, validUntil: expiry,
                                                         signedTransaction: nil, environment: transaction.environment))
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
        case .unavailable: String(localized: "This plan isn’t available right now. Please try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .unverified: String(localized: "Apple couldn’t verify this purchase. Try Restore purchases, or contact Apple Support if the charge appears in your purchase history.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .activation: String(localized: "Apple confirmed the transaction, but an active subscription isn’t available yet. Please try Restore purchases.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .busy: String(localized: "A purchase or restore is already in progress.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
}
