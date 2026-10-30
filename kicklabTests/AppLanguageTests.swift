import XCTest
import Observation
@testable import kicklab

@MainActor
final class AppLanguageTests: XCTestCase {
    func testChoicePersistsAndSystemOptionRemovesOnlyTheAppOverride() throws {
        let domain = "language-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.register(defaults: ["AppleLanguages": ["es-MX", "en"]])
        defaults.set("preserved", forKey: "session")
        let language = LanguagePreferences(defaults: defaults, domain: domain)
        let systemLanguage = language.selection.code
        language.choose("de")
        XCTAssertEqual(language.selection.code, "de")
        XCTAssertEqual(LanguagePreferences(defaults: defaults, domain: domain).selection.chosen, "de")
        language.choose(nil)
        XCTAssertNil(language.selection.chosen)
        XCTAssertEqual(language.selection.code, systemLanguage)
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
        XCTAssertEqual(defaults.string(forKey: "session"), "preserved")
        language.choose("unsupported")
        XCTAssertEqual(language.selection.code, systemLanguage)
    }

    func testRefreshPicksUpExternalPreferenceChangesAndNotifiesReaders() throws {
        let domain = "language-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let language = LanguagePreferences(defaults: defaults, domain: domain)
        language.choose("en")
        let changed = expectation(description: "Existing views observe a language change")
        withObservationTracking { _ = language.selection } onChange: { changed.fulfill() }
        defaults.set(["pt-BR"], forKey: "AppleLanguages")
        language.refresh()
        XCTAssertEqual(language.selection.code, "pt-BR")
        wait(for: [changed], timeout: 1)
    }

    func testResolvedMessagesResourcesAndCachedLabelsFollowLiveChoice() {
        let original = AppLanguage.chosen
        defer { AppLanguage.choose(original) }
        let resource = LocalizedStringResource("history.filter.all", defaultValue: "All")
        for (code, week, error, all, heading, country, purchase) in [
            ("en", "This week", "Enter a valid email address.", "All", "Processing your session", "Germany", "Get Pro · €4.99/month"),
            ("de", "Diese Woche", "Gib eine gültige E-Mail-Adresse ein.", "Alle", "Training wird verarbeitet", "Deutschland", "Pro holen · €4.99/Monat"),
            ("fr", "Cette semaine", "Saisis une adresse e-mail valide.", "Toutes", "Traitement de ta séance", "Allemagne", "Passer à Pro · €4.99/mois"),
            ("en", "This week", "Enter a valid email address.", "All", "Processing your session", "Germany", "Get Pro · €4.99/month")
        ] {
            AppLanguage.choose(code)
            XCTAssertEqual(LeaderboardPeriod.week.title, week)
            XCTAssertEqual(AccountFailure.invalidEmail.errorDescription, error)
            XCTAssertEqual(String(localized: AppLanguage.resource(resource)), all)
            XCTAssertEqual(ProcessingLabels.juggling.heading, heading)
            XCTAssertEqual(ProfileCountry.named("DE")?.name, country)
            // The storefront price is an unchanged interpolation, not re-priced in the UI locale.
            XCTAssertEqual(ProPlan.monthly.buyLabel(price: "€4.99"), purchase)
        }
    }
}
