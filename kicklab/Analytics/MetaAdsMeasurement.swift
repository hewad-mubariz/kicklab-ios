import AppTrackingTransparency
import Combine
import FBSDKCoreKit
import StoreKit
import UIKit

@MainActor
protocol AdTrackingAuthorizing: AnyObject {
    var status: ATTrackingManager.AuthorizationStatus { get }
    func request() async -> ATTrackingManager.AuthorizationStatus
}

@MainActor
private final class SystemAdTrackingAuthorization: AdTrackingAuthorizing {
    var status: ATTrackingManager.AuthorizationStatus { ATTrackingManager.trackingAuthorizationStatus }
    func request() async -> ATTrackingManager.AuthorizationStatus {
        await ATTrackingManager.requestTrackingAuthorization()
    }
}

@MainActor
protocol MetaInstallMeasuring: AnyObject {
    func start()
    func activateApp()
    func log(_ event: MetaAdsMeasurement.Event)
}

/// The Meta SDK, started only by MetaAdsMeasurement once measurement is allowed where this person is.
@MainActor
private final class FacebookInstallMeasurement: MetaInstallMeasuring {
    func start() {
        // Info.plist sets the same before the SDK reads anything. Launch URLs are not forwarded:
        // they can carry sign-in tokens.
        _ = ApplicationDelegate.shared.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
        Settings.shared.isAutoLogAppEventsEnabled = false
        Settings.shared.isMetaDataCollectionEnabled = false
        Settings.shared.isAutoLogProductImprovementEnabled = false
        Settings.shared.isCodelessDebugLogEnabled = false
        Settings.shared.isEventDataUsageLimited = true
        // The SDK reads the tracking answer on every request: the advertising identifier goes only
        // with Allow; otherwise events go to Meta's non-tracking endpoint without it.
        Settings.shared.isAdvertiserIDCollectionEnabled = true
        Settings.shared.isSKAdNetworkReportEnabled = true
    }

    func activateApp() {
        AppEvents.shared.activateApp()
        AppEvents.shared.flush()
    }

    func log(_ event: MetaAdsMeasurement.Event) {
        switch event {
        case .firstTraining: AppEvents.shared.logEvent(.completedTutorial)
        case .startTrial(let currency): AppEvents.shared.logEvent(.startTrial, parameters: [.currency: currency])
        case .subscribe(let price, let currency):
            AppEvents.shared.logEvent(.subscribe, valueToSum: price, parameters: [.currency: currency])
        }
        AppEvents.shared.flush()
    }
}

/// Measures Facebook and Instagram install ads. Separate from opt-in PostHog analytics.
///
/// Outside the EEA, the UK and Switzerland it follows Meta's standard setup: the SDK runs for everyone
/// and reads the tracking answer itself, adding the advertising identifier only with Allow. Inside
/// them, where sharing with Meta needs consent, nothing reaches Meta until Allow, and an event from
/// before the answer waits for it. Apple's SKAdNetwork registers every install either way; Apple
/// reports it to the ad network without data from this app.
///
/// Meta receives: installs and opens, the first finished training, and a Pro trial or subscription
/// start with its price. Never videos, touch counts or account details.
@MainActor
final class MetaAdsMeasurement: ObservableObject {
    enum Event: Equatable { case firstTraining, startTrial(currency: String), subscribe(price: Double, currency: String) }

    static let shared = MetaAdsMeasurement(
        authorization: SystemAdTrackingAuthorization(), transport: FacebookInstallMeasurement(),
        allowed: runtimeAllowsMeasurement, defaults: .standard,
        needsConsent: { await storefrontNeedsConsent() }, registerInstall: registerInstallWithApple
    )

    @Published private(set) var authorizationStatus: ATTrackingManager.AuthorizationStatus
    @Published private(set) var isRequesting = false
    /// The tracking question waits for a first finished training, or the third launch without one.
    @Published private(set) var wantsPermission: Bool
    let isAvailable: Bool
    private let authorization: any AdTrackingAuthorizing
    private let transport: any MetaInstallMeasuring
    private let defaults: UserDefaults
    private let resolveConsent: () async -> Bool
    private var needsConsent: Bool?
    private var isActive = false, started = false, needsActivation = false
    /// Events from before a consent region's answer; sent on Allow, dropped otherwise.
    private var held: [Event] = []

    private static let launchesKey = "kicklab.meta.launches", trainedKey = "kicklab.meta.firstTrainingLogged"
    private static let registeredKey = "kicklab.meta.skanRegistered"

    init(authorization: any AdTrackingAuthorizing, transport: any MetaInstallMeasuring, allowed: Bool,
         defaults: UserDefaults, needsConsent: @escaping () async -> Bool, registerInstall: () -> Void) {
        self.authorization = authorization
        self.transport = transport
        self.defaults = defaults
        resolveConsent = needsConsent
        isAvailable = allowed
        authorizationStatus = authorization.status
        let launches = defaults.integer(forKey: Self.launchesKey) + (allowed ? 1 : 0)
        defaults.set(launches, forKey: Self.launchesKey)
        wantsPermission = defaults.bool(forKey: Self.trainedKey) || launches >= 3
        if allowed && !defaults.bool(forKey: Self.registeredKey) {
            registerInstall()
            defaults.set(true, forKey: Self.registeredKey)
        }
    }

    /// May the SDK run now: outside consent regions always, inside them only with Allow.
    private var mayMeasure: Bool {
        guard isAvailable, let needsConsent else { return false }
        return !needsConsent || authorizationStatus == .authorized
    }

    func sceneChanged(isActive active: Bool) async {
        if active && !isActive { needsActivation = true }
        isActive = active
        authorizationStatus = authorization.status
        guard isAvailable else { return }
        if needsConsent == nil { needsConsent = await resolveConsent() }
        if needsConsent == true && authorizationStatus != .notDetermined && !mayMeasure { held.removeAll() }
        measureIfAllowed()
    }

    func requestPermission() async {
        authorizationStatus = authorization.status
        guard isAvailable, isActive, !isRequesting, authorizationStatus == .notDetermined else { return }
        isRequesting = true
        _ = await authorization.request()
        isRequesting = false
        authorizationStatus = authorization.status
        // With Allow, open again now so this session's measurement can carry the identifier.
        if authorizationStatus == .authorized { needsActivation = true } else if needsConsent == true { held.removeAll() }
        measureIfAllowed()
    }

    /// A finished training session: the first one is the activation event, and opens the tracking question.
    func trainingCompleted() {
        guard isAvailable, !defaults.bool(forKey: Self.trainedKey) else { return }
        defaults.set(true, forKey: Self.trainedKey)
        wantsPermission = true
        log(.firstTraining)
    }

    /// A verified Pro purchase: a free trial, or a paid start with its price.
    func subscriptionStarted(freeTrial: Bool, price: Decimal, currency: String) {
        log(freeTrial ? .startTrial(currency: currency) : .subscribe(price: NSDecimalNumber(decimal: price).doubleValue, currency: currency))
    }

    private func log(_ event: Event) {
        guard isAvailable else { return }
        if mayMeasure {
            startIfNeeded()
            transport.log(event)
        } else if needsConsent == nil || authorizationStatus == .notDetermined {
            // The region is not known yet, or a consent region has not answered.
            held.append(event)
        }
    }

    private func measureIfAllowed() {
        guard mayMeasure else { return }
        if isActive && needsActivation {
            startIfNeeded()
            needsActivation = false
            transport.activateApp()
        }
        if !held.isEmpty {
            startIfNeeded()
            held.forEach(transport.log)
            held.removeAll()
        }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        transport.start()
    }

    /// Where sharing with Meta for advertising needs consent: the EEA, the UK and Switzerland, by App
    /// Store storefront (ISO 3166 alpha-3). An unknown storefront counts as one of them.
    static let consentStorefronts: Set<String> = [
        "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN", "IRL", "ITA",
        "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE", "ISL", "LIE", "NOR",
        "GBR", "CHE"]

    private static func storefrontNeedsConsent() async -> Bool {
        guard let country = await Storefront.current?.countryCode else { return true }
        return consentStorefronts.contains(country)
    }

    /// Apple's SKAdNetwork: the first conversion value registers the install for ad attribution.
    /// No data from this app goes to Meta; Apple sends its own anonymous postback.
    private static func registerInstallWithApple() {
        SKAdNetwork.updatePostbackConversionValue(0, coarseValue: .low, lockWindow: false) { _ in }
    }

    private static var runtimeAllowsMeasurement: Bool {
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        // Release gate in Info.plist; tests and previews never measure.
        guard bundle.object(forInfoDictionaryKey: "JuggleDudeMetaAdsEnabled") as? Bool == true,
              let appID = bundle.object(forInfoDictionaryKey: "FacebookAppID") as? String,
              appID == "1439446130906551",
              let token = bundle.object(forInfoDictionaryKey: "FacebookClientToken") as? String,
              token.count == 32, token.allSatisfy(\.isHexDigit),
              process.environment["XCTestConfigurationFilePath"] == nil,
              process.environment["XCTestBundlePath"] == nil,
              process.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return false }
        #if DEBUG
        return process.arguments.contains("--enable-meta-install-measurement")
        #else
        return true
        #endif
    }
}
