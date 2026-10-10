import Combine
import Foundation
import PostHog

/// Deliberately explicit product events. Never pass URLs, errors, emails or media to this API.
enum ProductEvent {
    enum Activity: String { case juggling, ballDistance = "ball_distance" }
    enum Outcome: String { case completed, cancelled, failed, pending }
    case appOpened
    case signInStarted(SignInProvider)
    case signInFinished(SignInProvider, Outcome)
    case emailLinkRequested(Outcome)
    case trainingStarted(Activity)
    case trainingCompleted(Activity, duration: Double)
    case importStarted
    case importFinished(Outcome)
    case exportStarted(Activity, effect: String, graph: Bool)
    case exportFinished(Activity, Outcome, elapsed: Double)
    case effectSelected(Activity, effect: String)
    case graphToggled(Bool)
    case paywallViewed
    case purchaseStarted(ProPlan)
    case purchaseFinished(ProPlan, Outcome)

    var payload: (name: String, properties: [String: Any]) {
        switch self {
        case .appOpened: ("app_opened", [:])
        case .signInStarted(let provider): ("sign_in_started", ["method": provider.rawValue])
        case .signInFinished(let provider, let outcome):
            ("sign_in_finished", ["method": provider.rawValue, "outcome": outcome.rawValue])
        case .emailLinkRequested(let outcome): ("email_link_requested", ["outcome": outcome.rawValue])
        case .trainingStarted(let activity): ("training_started", ["activity": activity.rawValue])
        case .trainingCompleted(let activity, let duration):
            ("training_completed", ["activity": activity.rawValue, "duration_seconds": Self.seconds(duration)])
        case .importStarted: ("video_import_started", ["activity": "juggling"])
        case .importFinished(let outcome): ("video_import_finished", ["activity": "juggling", "outcome": outcome.rawValue])
        case .exportStarted(let activity, let effect, let graph):
            ("video_export_started", ["activity": activity.rawValue, "effect": effect, "graph_enabled": graph])
        case .exportFinished(let activity, let outcome, let elapsed):
            ("video_export_finished", ["activity": activity.rawValue, "outcome": outcome.rawValue,
                                       "elapsed_seconds": Self.seconds(elapsed)])
        case .effectSelected(let activity, let effect):
            ("effect_selected", ["activity": activity.rawValue, "effect": effect])
        case .graphToggled(let enabled): ("motion_graph_toggled", ["enabled": enabled])
        case .paywallViewed: ("paywall_viewed", [:])
        case .purchaseStarted(let plan): ("purchase_started", ["plan": plan.rawValue])
        case .purchaseFinished(let plan, let outcome):
            ("purchase_finished", ["plan": plan.rawValue, "outcome": outcome.rawValue])
        }
    }

    private static func seconds(_ value: Double) -> Int {
        value.isFinite ? Int(min(604_800, max(0, value)).rounded()) : 0
    }
}

struct ProductAnalyticsConfiguration {
    let token: String
    let host: String

    init?(values: [String: String]) {
        guard let token = values["POSTHOG_PROJECT_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              token.hasPrefix("phc_"), token.count > 12, !token.contains("REPLACE_ME"),
              let host = values["POSTHOG_HOST"],
              ["https://eu.i.posthog.com", "https://us.i.posthog.com"].contains(host) else { return nil }
        self.token = token
        self.host = host
    }

    static func load(bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(forResource: "PostHogConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return nil }
        return Self(values: values)
    }
}

@MainActor
protocol ProductAnalyticsTransport {
    func start(_ configuration: ProductAnalyticsConfiguration)
    func setEnabled(_ enabled: Bool)
    func capture(_ name: String, properties: [String: Any])
    func resetIdentity()
}

@MainActor
private final class PostHogTransport: ProductAnalyticsTransport {
    func start(_ configuration: ProductAnalyticsConfiguration) {
        let config = PostHogConfig(projectToken: configuration.token, host: configuration.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.captureSwiftUIElementInteractions = false
        config.enableSwizzling = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.sessionReplay = false
        config.errorTrackingConfig.autoCapture = false
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.disableGeoIp = true
        config.maxQueueSize = 300
        PostHogSDK.shared.setup(config)
    }
    func setEnabled(_ enabled: Bool) {
        if enabled { PostHogSDK.shared.optIn() } else { PostHogSDK.shared.optOut() }
    }
    func capture(_ name: String, properties: [String: Any]) {
        PostHogSDK.shared.capture(name, properties: properties)
    }
    func resetIdentity() { PostHogSDK.shared.reset() }
}

/// No SDK setup/networking until the user opts in. Debug/tests/previews never send by default.
/// Anonymous installation IDs support retention without linking analytics to an account.
@MainActor
final class ProductAnalytics: ObservableObject {
    static let preferenceKey = "juggledude.analytics.enabled"
    static let shared = ProductAnalytics(configuration: .load(), transport: PostHogTransport(),
                                         allowed: runtimeAllowsTracking)
    @Published private(set) var isEnabled: Bool
    private let defaults: UserDefaults
    private let configuration: ProductAnalyticsConfiguration?
    private let transport: any ProductAnalyticsTransport
    private let allowed: Bool
    private var started = false

    init(configuration: ProductAnalyticsConfiguration?, transport: any ProductAnalyticsTransport,
         defaults: UserDefaults = .standard, allowed: Bool) {
        self.configuration = configuration
        self.transport = transport
        self.defaults = defaults
        self.allowed = allowed
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        if enabled { startIfNeeded() }
        else if started { transport.setEnabled(false) }
    }

    func track(_ event: ProductEvent) {
        guard isEnabled, allowed, configuration != nil else { return }
        startIfNeeded()
        let payload = event.payload
        var properties = payload.properties
        properties["event_schema_version"] = 1
        #if DEBUG
        properties["environment"] = "development"
        #else
        properties["environment"] = "production"
        #endif
        transport.capture(payload.name, properties: properties)
    }

    func resetIdentity() {
        guard started else { return }
        transport.resetIdentity()
    }

    private func startIfNeeded() {
        guard isEnabled, allowed, let configuration else { return }
        if !started { transport.start(configuration); started = true }
        transport.setEnabled(true)
    }

    private static var runtimeAllowsTracking: Bool {
        let process = ProcessInfo.processInfo
        guard process.environment["XCTestConfigurationFilePath"] == nil,
              process.environment["XCTestBundlePath"] == nil,
              process.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return false }
        #if DEBUG
        return process.arguments.contains("--enable-product-analytics")
        #else
        return true
        #endif
    }
}
