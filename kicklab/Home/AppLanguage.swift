import SwiftUI
import Observation
import os

/// Both the picker and iOS Settings use AppleLanguages. Resolve the app's copy ourselves
/// so changing it also takes effect during this process, without replacing the view tree.
nonisolated enum AppLanguage {
    static let supported = ["en", "de", "es", "fr", "pt-BR"]
    fileprivate static let key = "AppleLanguages"
    private static let preferences = LanguagePreferences(defaults: .standard)

    static var current: String { preferences.selection.code }
    static var chosen: String? { preferences.selection.chosen }
    static var locale: Locale { Locale(identifier: current) }

    /// String(localized:) outside SwiftUI must look up this bundle. Its locale argument
    /// alone only formats substitutions; it doesn't select the translated string.
    static var bundle: Bundle { bundles[current] ?? .main }
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: supported.compactMap { code in
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return (code, bundle)
    })

    static func resource(_ resource: LocalizedStringResource) -> LocalizedStringResource {
        var resource = resource
        resource.locale = locale
        return resource
    }

    @MainActor static func choose(_ code: String?) { preferences.choose(code) }
    @MainActor static func refresh() { preferences.refresh() }


    /// What its own speakers call it: Deutsch, Español, Português. The region is left out;
    /// each language ships one variant.
    static func name(_ code: String) -> String { name(code, in: Locale(identifier: code)) }

    /// The same language named in the interface's language, shown beneath.
    static func localName(_ code: String) -> String { name(code, in: locale) }

    private static func name(_ code: String, in locale: Locale) -> String {
        let language = Locale(identifier: code).language.languageCode?.identifier ?? code
        return locale.localizedString(forLanguageCode: language)?.capitalized(with: locale) ?? code
    }

    fileprivate static func match(_ preferences: [String]) -> String? {
        Bundle.preferredLocalizations(from: supported, forPreferences: preferences).first
    }
}

/// Observation keeps already-open views that render plain Strings up to date too.
/// A locked snapshot makes the same selection safe to read from video/export workers.
/// Preference writes and observation notifications always happen on the main actor.
nonisolated final class LanguagePreferences: Observable, @unchecked Sendable {
    struct Selection: Equatable, Sendable {
        let chosen: String?
        let code: String
    }

    private let defaults: UserDefaults
    private let domain: String
    private let registrar = ObservationRegistrar()
    private let snapshot: OSAllocatedUnfairLock<Selection>

    init(defaults: UserDefaults, domain: String = Bundle.main.bundleIdentifier ?? "") {
        self.defaults = defaults
        self.domain = domain
        snapshot = OSAllocatedUnfairLock(initialState: Self.read(defaults, domain: domain))
    }

    var selection: Selection {
        registrar.access(self, keyPath: \.selection)
        return snapshot.withLock { $0 }
    }

    @MainActor func choose(_ code: String?) {
        if let code, !AppLanguage.supported.contains(code) { return }
        if let code { defaults.set([code], forKey: AppLanguage.key) }
        else { defaults.removeObject(forKey: AppLanguage.key) }
        refresh()
    }

    @MainActor func refresh() {
        let updated = Self.read(defaults, domain: domain)
        guard updated != selection else { return }
        registrar.withMutation(of: self, keyPath: \.selection) {
            snapshot.withLock { $0 = updated }
        }
    }

    private static func read(_ defaults: UserDefaults, domain: String) -> Selection {
        let own = defaults.persistentDomain(forName: domain)?[AppLanguage.key] as? [String]
        // Removing the app override exposes the iPhone's languages from the defaults
        // search list. Don't use Bundle.preferredLocalizations, which caches at launch.
        return Selection(chosen: own.flatMap(AppLanguage.match),
                         code: AppLanguage.match(defaults.stringArray(forKey: AppLanguage.key) ?? []) ?? "en")
    }
}

struct AppLanguageEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.locale, AppLanguage.locale)
    }
}

struct AppLanguagePicker: View {
    @Environment(\.colorScheme) private var scheme
    private var chosen: String? { AppLanguage.chosen }

    var body: some View {
        Form {
            Section {
                option(nil) { Text("Same as iPhone") }
                ForEach(AppLanguage.supported, id: \.self) { code in
                    option(code) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: AppLanguage.name(code))
                            Text(verbatim: AppLanguage.localName(code))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Juggle Dude follows your iPhone’s language unless you pick one here.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(TrainingHomeStyle.background(scheme))
        .navigationTitle(String(localized: "Language", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private func option<Label: View>(_ code: String?, @ViewBuilder label: () -> Label) -> some View {
        Button {
            AppLanguage.choose(code)
        } label: {
            HStack {
                label()
                Spacer(minLength: 8)
                if chosen == code {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                }
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityAddTraits(chosen == code ? .isSelected : [])
        .accessibilityIdentifier("language-\(code ?? "system")")
    }
}
