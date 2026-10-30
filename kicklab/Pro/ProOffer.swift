import Foundation
import StoreKit

nonisolated enum ProPlan: String, CaseIterable, Identifiable, Sendable {
    case monthly, yearly
    var id: String { rawValue }
    var title: String { self == .monthly ? String(localized: "Monthly", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : String(localized: "Yearly", bundle: AppLanguage.bundle, locale: AppLanguage.locale) }
    /// Follows a price: "€4.99 / month".
    var perPeriod: String { self == .monthly ? String(localized: "/ month", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : String(localized: "/ year", bundle: AppLanguage.bundle, locale: AppLanguage.locale) }

    func buyLabel(price: String) -> String {
        self == .monthly ? String(localized: "Get Pro · \(price)/month", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : String(localized: "Get Pro · \(price)/year", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }

    func spokenPrice(_ price: String) -> String {
        self == .monthly ? String(localized: "\(price) per month", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : String(localized: "\(price) per year", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
    var productID: String { "com.hewad.juggledude.pro.\(rawValue)" }

    init?(productID: String) {
        guard let plan = Self.allCases.first(where: { $0.productID == productID }) else { return nil }
        self = plan
    }

    func matches(_ product: Product) -> Bool {
        guard product.type == .autoRenewable, let subscription = product.subscription else { return false }
        let period = subscription.subscriptionPeriod
        return period.value == 1 && period.unit == (self == .monthly ? .month : .year)
    }
}

/// All price strings and savings use the current App Store storefront. No fallback sale price.
nonisolated struct ProOffer {
    let plan: ProPlan
    let price: String
    let perMonth: String?
    let badge: String?

    init(plan: ProPlan, product: Product, monthly: Product?) {
        self.plan = plan
        price = product.displayPrice
        perMonth = plan == .yearly ? String(localized: "About \((product.price / 12).formatted(product.priceFormatStyle)) / month", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : nil
        let comparable = monthly?.priceFormatStyle.currencyCode == product.priceFormatStyle.currencyCode
        if plan == .yearly, comparable, let monthly,
           let percent = Self.savingPercent(monthly: monthly.price, yearly: product.price) {
            badge = String(localized: "Save \(percent)%", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        } else {
            badge = nil
        }
    }

    static func savingPercent(monthly: Decimal, yearly: Decimal) -> Int? {
        guard monthly > 0, yearly > 0, yearly < monthly * 12 else { return nil }
        let percent = NSDecimalNumber(decimal: (1 - yearly / (monthly * 12)) * 100).doubleValue
        let rounded = Int(percent.rounded())
        return rounded > 0 ? rounded : nil
    }

    var renewalTerms: String {
        plan == .monthly
            ? String(localized: "\(price) billed monthly to your Apple Account. Renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in Settings.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            : String(localized: "\(price) billed yearly to your Apple Account. Renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in Settings.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
}

nonisolated enum ProFeature: String, CaseIterable, Identifiable {
    case effects, balls, motion
    var id: String { rawValue }
    var title: String {
        switch self {
        case .effects: String(localized: "All effects", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .balls: String(localized: "Ball styles", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .motion: String(localized: "Graphs & counter styles", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
}
