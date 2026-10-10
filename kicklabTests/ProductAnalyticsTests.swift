import XCTest
@testable import kicklab

@MainActor
final class ProductAnalyticsTests: XCTestCase {
    private func configuration() -> ProductAnalyticsConfiguration {
        ProductAnalyticsConfiguration(values: ["POSTHOG_PROJECT_TOKEN": "phc_unit_test_only",
                                               "POSTHOG_HOST": "https://eu.i.posthog.com"])!
    }

    func testNoSetupOrCaptureBeforeOptInAndOptOutStopsFurtherEvents() {
        let defaults = UserDefaults(suiteName: "analytics-test-\(UUID())")!
        let transport = RecordingAnalyticsTransport()
        let analytics = ProductAnalytics(configuration: configuration(), transport: transport,
                                         defaults: defaults, allowed: true)
        analytics.track(.appOpened)
        XCTAssertEqual(transport.starts, 0)
        XCTAssertTrue(transport.events.isEmpty)

        analytics.setEnabled(true)
        analytics.track(.appOpened)
        analytics.track(.trainingStarted(.juggling))
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(transport.events.map(\.0), ["app_opened", "training_started"])

        analytics.setEnabled(false)
        analytics.track(.paywallViewed)
        XCTAssertFalse(transport.enabled)
        XCTAssertEqual(transport.events.count, 2)
        analytics.setEnabled(true)
        analytics.track(.paywallViewed)
        XCTAssertEqual(transport.starts, 1, "Re-enabling must not install the SDK twice")
        XCTAssertEqual(transport.events.count, 3)
        defaults.removeObject(forKey: ProductAnalytics.preferenceKey)
    }

    func testMissingConfigurationAndDisallowedRuntimeNeverStartSDK() {
        for (config, allowed) in [(nil, true), (Optional(configuration()), false)] {
            let defaults = UserDefaults(suiteName: "analytics-test-\(UUID())")!
            let transport = RecordingAnalyticsTransport()
            let analytics = ProductAnalytics(configuration: config, transport: transport, defaults: defaults, allowed: allowed)
            analytics.setEnabled(true)
            analytics.track(.appOpened)
            analytics.resetIdentity()
            XCTAssertEqual(transport.starts, 0)
            XCTAssertEqual(transport.resets, 0)
            XCTAssertTrue(transport.events.isEmpty)
            defaults.removeObject(forKey: ProductAnalytics.preferenceKey)
        }
    }

    func testSavedPreferenceAndIdentityResetDoNotNeedAnAccountIdentifier() {
        let defaults = UserDefaults(suiteName: "analytics-test-\(UUID())")!
        defaults.set(true, forKey: ProductAnalytics.preferenceKey)
        let transport = RecordingAnalyticsTransport()
        let analytics = ProductAnalytics(configuration: configuration(), transport: transport, defaults: defaults, allowed: true)
        XCTAssertTrue(analytics.isEnabled)
        XCTAssertEqual(transport.starts, 0, "Loading preferences must not start networking")
        analytics.track(.signInFinished(.email, .completed))
        analytics.resetIdentity()
        XCTAssertEqual(transport.resets, 1)
        XCTAssertEqual(Set(transport.events[0].1.keys), ["method", "outcome", "event_schema_version", "environment"])
        defaults.removeObject(forKey: ProductAnalytics.preferenceKey)
    }

    func testConfigurationRejectsPersonalKeysPlaceholdersAndUnapprovedHosts() {
        XCTAssertNotNil(configuration())
        for (token, host) in [("phx_personal_secret", "https://eu.i.posthog.com"),
                              ("phc_REPLACE_ME", "https://eu.i.posthog.com"),
                              ("phc_unit_test_only", "http://eu.i.posthog.com"),
                              ("phc_unit_test_only", "https://example.com")] {
            XCTAssertNil(ProductAnalyticsConfiguration(values: ["POSTHOG_PROJECT_TOKEN": token, "POSTHOG_HOST": host]))
        }
    }

    func testExportOutcomesAreBoundedAndDistinguishCancellationFromFailure() {
        let cancelled = ProductEvent.exportFinished(.ballDistance, .cancelled, elapsed: 30.4).payload
        XCTAssertEqual(cancelled.properties["outcome"] as? String, "cancelled")
        XCTAssertEqual(cancelled.properties["elapsed_seconds"] as? Int, 30)
        let failed = ProductEvent.exportFinished(.juggling, .failed, elapsed: .infinity).payload
        XCTAssertEqual(failed.properties["outcome"] as? String, "failed")
        XCTAssertEqual(failed.properties["elapsed_seconds"] as? Int, 0)
    }
}

@MainActor
private final class RecordingAnalyticsTransport: ProductAnalyticsTransport {
    var starts = 0
    var resets = 0
    var enabled = false
    var events: [(String, [String: Any])] = []
    func start(_ configuration: ProductAnalyticsConfiguration) { starts += 1 }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func capture(_ name: String, properties: [String: Any]) { events.append((name, properties)) }
    func resetIdentity() { resets += 1 }
}
