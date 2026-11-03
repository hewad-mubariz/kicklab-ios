import AppTrackingTransparency
import XCTest
@testable import kicklab

/// Meta measurement with a recording transport: no test starts the real SDK or sends anything.
@MainActor
final class MetaAdsMeasurementTests: XCTestCase {
    private func make(_ status: ATTrackingManager.AuthorizationStatus, response: ATTrackingManager.AuthorizationStatus? = nil,
                      consent: Bool, allowed: Bool = true, defaults: UserDefaults? = nil)
        -> (MetaAdsMeasurement, TestAdAuthorization, RecordingInstallMeasurement, Counter) {
        let authorization = TestAdAuthorization(status, response: response)
        let transport = RecordingInstallMeasurement()
        let registrations = Counter()
        let measurement = MetaAdsMeasurement(authorization: authorization, transport: transport, allowed: allowed,
                                             defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
                                             needsConsent: { consent }, registerInstall: { registrations.value += 1 })
        return (measurement, authorization, transport, registrations)
    }

    func testOutsideConsentRegionsTheSDKMeasuresWhateverTheAnswer() async {
        for status in [ATTrackingManager.AuthorizationStatus.notDetermined, .denied, .restricted, .authorized] {
            let (measurement, _, transport, registrations) = make(status, consent: false)
            await measurement.sceneChanged(isActive: true)
            await measurement.sceneChanged(isActive: false)
            await measurement.sceneChanged(isActive: true)
            XCTAssertEqual(transport.calls, ["start", "activate", "activate"], "\(status.rawValue): once per foreground")
            XCTAssertEqual(registrations.value, 1, "Apple registers the install once")
        }
    }

    func testInConsentRegionsNothingReachesMetaWithoutAllow() async {
        for status in [ATTrackingManager.AuthorizationStatus.notDetermined, .denied, .restricted] {
            let (measurement, _, transport, registrations) = make(status, consent: true)
            await measurement.sceneChanged(isActive: true)
            measurement.trainingCompleted()
            measurement.subscriptionStarted(freeTrial: true, price: 0, currency: "EUR")
            await measurement.sceneChanged(isActive: true)
            XCTAssertTrue(transport.calls.isEmpty, "\(status.rawValue)")
            XCTAssertEqual(registrations.value, 1, "SKAdNetwork carries no data from the app")
        }
    }

    func testAllowInAConsentRegionStartsAndSendsTheEventThatWaited() async {
        let (measurement, authorization, transport, _) = make(.notDetermined, response: .authorized, consent: true)
        await measurement.sceneChanged(isActive: true)
        measurement.trainingCompleted()
        XCTAssertTrue(transport.calls.isEmpty, "The first session waits for the answer")
        XCTAssertTrue(measurement.wantsPermission, "and opens the tracking question")
        await measurement.requestPermission()
        await measurement.requestPermission()
        XCTAssertEqual(authorization.requests, 1, "Asked once")
        XCTAssertEqual(transport.calls, ["start", "activate", "log firstTraining"])
    }

    func testNotAllowedInAConsentRegionDropsTheEventThatWaited() async {
        let (measurement, _, transport, _) = make(.notDetermined, response: .denied, consent: true)
        await measurement.sceneChanged(isActive: true)
        measurement.trainingCompleted()
        await measurement.requestPermission()
        await measurement.sceneChanged(isActive: false)
        await measurement.sceneChanged(isActive: true)
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testAllowOutsideConsentRegionsOpensAgainWithTheIdentifier() async {
        let (measurement, _, transport, _) = make(.notDetermined, response: .authorized, consent: false)
        await measurement.sceneChanged(isActive: true)
        measurement.trainingCompleted()
        await measurement.requestPermission()
        XCTAssertEqual(transport.calls, ["start", "activate", "log firstTraining", "activate"])
    }

    func testOnlyTheFirstTrainingIsAnEventAndPurchasesCarryTrialOrPrice() async {
        let (measurement, _, transport, _) = make(.denied, consent: false)
        await measurement.sceneChanged(isActive: true)
        measurement.trainingCompleted()
        measurement.trainingCompleted()
        measurement.subscriptionStarted(freeTrial: true, price: 29.99, currency: "EUR")
        measurement.subscriptionStarted(freeTrial: false, price: 29.99, currency: "USD")
        XCTAssertEqual(transport.calls, ["start", "activate", "log firstTraining", "log startTrial EUR", "log subscribe 29.99 USD"])
    }

    func testTheQuestionWaitsForAFirstTrainingOrTheThirdLaunch() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        for launch in 1...3 {
            let (measurement, _, _, _) = make(.notDetermined, consent: true, defaults: defaults)
            XCTAssertEqual(measurement.wantsPermission, launch == 3, "launch \(launch)")
        }
    }

    func testReleaseGateOffDoesNothingAtAll() async {
        let (measurement, authorization, transport, registrations) = make(.notDetermined, response: .authorized, consent: false, allowed: false)
        await measurement.sceneChanged(isActive: true)
        measurement.trainingCompleted()
        await measurement.requestPermission()
        XCTAssertEqual(authorization.requests, 0)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(registrations.value, 0)
    }

    func testWithdrawingConsentStopsNewEventsAndDoesNotBackfillThemLater() async {
        let (measurement, authorization, transport, _) = make(.authorized, consent: true)
        await measurement.sceneChanged(isActive: true)
        measurement.trainingCompleted()
        let beforeWithdrawal = transport.calls

        await measurement.sceneChanged(isActive: false)
        authorization.status = .denied
        await measurement.sceneChanged(isActive: true)
        measurement.subscriptionStarted(freeTrial: false, price: 29.99, currency: "EUR")
        XCTAssertEqual(transport.calls, beforeWithdrawal, "No new event is passed to Meta after consent is withdrawn")

        await measurement.sceneChanged(isActive: false)
        authorization.status = .authorized
        await measurement.sceneChanged(isActive: true)
        XCTAssertEqual(transport.calls, beforeWithdrawal + ["activate"], "A purchase made without consent cannot be backfilled")
    }

    func testPermissionRequestWaitsUntilTheAppIsActive() async {
        let (measurement, authorization, transport, _) = make(.notDetermined, response: .authorized, consent: true)
        measurement.trainingCompleted()
        await measurement.requestPermission()
        XCTAssertEqual(authorization.requests, 0)
        XCTAssertTrue(transport.calls.isEmpty)
        await measurement.sceneChanged(isActive: true)
        await measurement.requestPermission()
        XCTAssertEqual(authorization.requests, 1)
        XCTAssertEqual(transport.calls, ["start", "activate", "log firstTraining"])
    }

    func testConsentStorefrontsAreTheEEATheUKAndSwitzerland() {
        for country in ["DEU", "FRA", "IRL", "NOR", "GBR", "CHE"] { XCTAssertTrue(MetaAdsMeasurement.consentStorefronts.contains(country), country) }
        for country in ["USA", "CAN", "BRA", "AUS", "TUR"] { XCTAssertFalse(MetaAdsMeasurement.consentStorefronts.contains(country), country) }
        XCTAssertEqual(MetaAdsMeasurement.consentStorefronts.count, 32, "27 EU, 3 EEA, the UK and Switzerland")
    }

    func testBundledSettingsKeepAutomaticCollectionOffAndTestsNeverMeasure() {
        let bundle = Bundle.main
        for language in ["en", "de", "es", "fr", "pt-BR"] {
            let path = bundle.path(forResource: language, ofType: "lproj")
            let localized = path.flatMap { Bundle(path: $0) }
            let explanation = localized?.localizedString(forKey: "NSUserTrackingUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertTrue(explanation?.contains("Meta") == true, "The \(language) system prompt must name the recipient")
        }
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "FacebookAppID") as? String, "1439446130906551")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "JuggleDudeMetaAdsEnabled") as? Bool, true)
        for key in ["FacebookAdvertiserIDCollectionEnabled", "FacebookSKAdNetworkReportEnabled"] {
            XCTAssertEqual(bundle.object(forInfoDictionaryKey: key) as? Bool, true, key)
        }
        for key in ["FacebookAutoLogAppEventsEnabled", "FacebookCodelessDebugLogEnabled", "FBSDKAutoLogMetaDataEnabled",
                    "FBSDKAutoLogProductImprovementEnabled", "FBSDKAemAutoSetupEnabled"] {
            XCTAssertEqual(bundle.object(forInfoDictionaryKey: key) as? Bool, false, key)
        }
        XCTAssertFalse(MetaAdsMeasurement.shared.isAvailable, "Tests never start the real SDK")
    }
}

@MainActor
private final class Counter { var value = 0 }

@MainActor
private final class TestAdAuthorization: AdTrackingAuthorizing {
    var status: ATTrackingManager.AuthorizationStatus
    var response: ATTrackingManager.AuthorizationStatus
    var requests = 0
    init(_ status: ATTrackingManager.AuthorizationStatus, response: ATTrackingManager.AuthorizationStatus? = nil) {
        self.status = status
        self.response = response ?? status
    }
    func request() async -> ATTrackingManager.AuthorizationStatus {
        requests += 1
        status = response
        return status
    }
}

@MainActor
private final class RecordingInstallMeasurement: MetaInstallMeasuring {
    var calls: [String] = []
    func start() { calls.append("start") }
    func activateApp() { calls.append("activate") }
    func log(_ event: MetaAdsMeasurement.Event) {
        switch event {
        case .firstTraining: calls.append("log firstTraining")
        case .startTrial(let currency): calls.append("log startTrial \(currency)")
        case .subscribe(let price, let currency): calls.append("log subscribe \(price) \(currency)")
        }
    }
}
