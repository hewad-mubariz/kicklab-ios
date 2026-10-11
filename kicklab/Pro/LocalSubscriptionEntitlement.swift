import Foundation
import StoreKit

struct LocalSubscriptionEntitlement {
    let plan: ProPlan
    let validUntil: Date
    let signedTransaction: String?
    var environment: AppStore.Environment? = nil
}

@MainActor
protocol LocalSubscriptionEntitlementSource {
    func current() async -> LocalSubscriptionEntitlement?
}

/// StoreKit can retain sandbox state across app installs. A cached transaction
/// must have a future expiry or a verified, still-active Apple billing grace period.
struct LocalSubscriptionAccess {
    static func validUntil(expiration: Date?, verifiedGraceEnd: Date?, now: Date = Date()) -> Date? {
        if let expiration, expiration > now { return expiration }
        if let verifiedGraceEnd, verifiedGraceEnd > now { return verifiedGraceEnd }
        return nil
    }

    static func allows(_ environment: AppStore.Environment, localTesting: Bool) -> Bool {
        environment == .production || environment == .sandbox || (localTesting && environment == .xcode)
    }

    static var allowsLocalTesting: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

@MainActor
struct StoreKitEntitlementSource: LocalSubscriptionEntitlementSource {
    func current() async -> LocalSubscriptionEntitlement? {
        var latest: (purchase: Date, entitlement: LocalSubscriptionEntitlement)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let plan = ProPlan(productID: transaction.productID),
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  LocalSubscriptionAccess.allows(transaction.environment,
                      localTesting: LocalSubscriptionAccess.allowsLocalTesting) else { continue }
            var graceEnd: Date?
            if transaction.expirationDate.map({ $0 <= Date() }) ?? true,
               let status = await transaction.subscriptionStatus, status.state == .inGracePeriod,
               case .verified(let renewal) = status.renewalInfo,
               case .verified(let current) = status.transaction,
               current.originalID == transaction.originalID, current.productID == transaction.productID,
               current.environment == transaction.environment, current.revocationDate == nil, !current.isUpgraded,
               renewal.originalTransactionID == transaction.originalID,
               renewal.currentProductID == transaction.productID, renewal.environment == transaction.environment {
                graceEnd = renewal.gracePeriodExpirationDate
            }
            guard let end = LocalSubscriptionAccess.validUntil(expiration: transaction.expirationDate,
                                                               verifiedGraceEnd: graceEnd) else { continue }
            if latest == nil || transaction.purchaseDate > latest!.purchase {
                let proof = transaction.environment == .xcode ? nil : result.jwsRepresentation
                latest = (transaction.purchaseDate, LocalSubscriptionEntitlement(plan: plan,
                    validUntil: end, signedTransaction: proof, environment: transaction.environment))
            }
        }
        return latest?.entitlement
    }
}
