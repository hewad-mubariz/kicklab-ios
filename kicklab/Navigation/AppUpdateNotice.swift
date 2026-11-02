import Combine
import SwiftUI

/// Tells people on an older version that a newer one is in the App Store. The App Store's public
/// lookup is the source, so announcing a release needs no server change; it can trail a release by
/// up to a day while Apple's cache refreshes. Each version is announced once, and never to a phone
/// whose iOS is too old to install it.
@MainActor
final class AppUpdateNotice: ObservableObject {
    nonisolated struct Release: Equatable, Sendable {
        let version: String
        let notes: String?
        let minimumOS: String?

        /// The first line of the release notes, or a plain line when there are none.
        var headline: String {
            let first = notes?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            return first.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "New features and fixes are ready.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }

    static let shared: AppUpdateNotice = {
        #if DEBUG
        // UI tests and screenshots: --app-update-preview announces a made-up next version.
        if ProcessInfo.processInfo.arguments.contains("--app-update-preview") {
            let defaults = UserDefaults(suiteName: "kicklab.app-update-preview")!
            defaults.removePersistentDomain(forName: "kicklab.app-update-preview")
            return AppUpdateNotice(installed: "1.2.0", defaults: defaults, lookup: { _ in
                Release(version: "1.3.0", notes: "Crystal ice, a fireworks show and four new balls.", minimumOS: nil)
            })
        }
        #endif
        return AppUpdateNotice()
    }()
    static let appStoreID = "6820780610"
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id\(appStoreID)")!

    /// A newer release this phone can install, once found.
    @Published private(set) var available: Release?
    @Published private(set) var dismissedVersion: String?

    private let installed: String
    private let systemVersion: String
    private let defaults: UserDefaults
    private let lookup: @Sendable (String?) async -> Release?
    private var lastCheck: Date?
    private static let dismissedKey = "kicklab.update.dismissedVersion"

    init(installed: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         systemVersion: String = AppUpdateNotice.installedOS, defaults: UserDefaults = .standard,
         lookup: @escaping @Sendable (String?) async -> Release? = { await AppUpdateNotice.appStoreRelease(region: $0) }) {
        self.installed = installed
        self.systemVersion = systemVersion
        self.defaults = defaults
        self.lookup = lookup
        dismissedVersion = defaults.string(forKey: Self.dismissedKey)
    }

    /// The home banner shows a found release until the person updates or dismisses that version.
    var showsBanner: Bool { available.map { $0.version != dismissedVersion } ?? false }

    /// Looks for a newer release, at most every six hours.
    func check(now: Date = .now) async {
        if let lastCheck, now.timeIntervalSince(lastCheck) < 6 * 3600 { return }
        lastCheck = now
        guard let release = await lookup(Locale.current.region?.identifier) else { return }
        let installable = release.minimumOS.map { !Self.isNewer($0, than: systemVersion) } ?? true
        available = Self.isNewer(release.version, than: installed) && installable ? release : nil
    }

    func dismiss() {
        guard let version = available?.version else { return }
        dismissedVersion = version
        defaults.set(version, forKey: Self.dismissedKey)
    }

    nonisolated static var installedOS: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    /// Dotted numeric versions: "1.10" is newer than "1.9", and "1.2" is the same as "1.2.0".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The App Store's public lookup for this app, in the person's own storefront, else the default one.
    nonisolated static func appStoreRelease(region: String?) async -> Release? {
        func fetch(_ country: String?) async -> Release? {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [URLQueryItem(name: "id", value: appStoreID)]
                + (country.map { [URLQueryItem(name: "country", value: $0.lowercased())] } ?? [])
            let request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try? JSONDecoder().decode(Lookup.self, from: data).results.first else { return nil }
            return Release(version: result.version, notes: result.releaseNotes, minimumOS: result.minimumOsVersion)
        }
        if let region, let release = await fetch(region) { return release }
        return await fetch(nil)
    }

    private nonisolated struct Lookup: Decodable {
        nonisolated struct Result: Decodable { let version: String; let releaseNotes: String?; let minimumOsVersion: String? }
        let results: [Result]
    }
}

/// The update banner on the home screen: the new version, its first line of notes, Update or not now.
struct AppUpdateBanner: View {
    @ObservedObject var notice: AppUpdateNotice
    @Environment(\.openURL) private var openURL

    var body: some View {
        if notice.showsBanner, let release = notice.available {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.app.fill").font(.title2).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Juggle Dude \(release.version) is here").font(.callout.weight(.semibold))
                    Text(release.headline).font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Button("Update") { openURL(AppUpdateNotice.appStoreURL) }
                        .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 4)
                        .accessibilityIdentifier("app-update-open")
                }
                Spacer(minLength: 0)
                Button("Not now", systemImage: "xmark") { withAnimation(.smooth) { notice.dismiss() } }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("app-update-dismiss")
            }
            .padding(16).foregroundStyle(.primary)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("app-update-banner")
        }
    }
}
