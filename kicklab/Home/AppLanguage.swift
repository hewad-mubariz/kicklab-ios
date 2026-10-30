import SwiftUI

/// The interface language. Juggle Dude follows the iPhone's language list unless a language is
/// picked here or in Settings › Apps › Juggle Dude › Language. Both store the same
/// `AppleLanguages` preference in the app's own defaults, and iOS applies it at the next launch.
enum AppLanguage {
    static let supported = ["en", "de", "es", "fr", "pt-BR"]
    private static let key = "AppleLanguages"

    /// The language this launch runs in.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The language picked for this app, or nil to follow the iPhone.
    static var chosen: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let preferences = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String] else { return nil }
        return match(preferences)
    }

    /// The language the next launch will use.
    static var next: String { match(UserDefaults.standard.stringArray(forKey: key) ?? []) ?? "en" }

    static func choose(_ code: String?) {
        if let code { UserDefaults.standard.set([code], forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// What its own speakers call it: Deutsch, Español, Português. The region is left out;
    /// each language ships one variant.
    static func name(_ code: String) -> String { name(code, in: Locale(identifier: code)) }

    /// The same language named in the interface's language, shown beneath.
    static func localName(_ code: String) -> String { name(code, in: .current) }

    private static func name(_ code: String, in locale: Locale) -> String {
        let language = Locale(identifier: code).language.languageCode?.identifier ?? code
        return locale.localizedString(forLanguageCode: language)?.capitalized(with: locale) ?? code
    }

    private static func match(_ preferences: [String]) -> String? {
        Bundle.preferredLocalizations(from: supported, forPreferences: preferences).first
    }
}

struct AppLanguagePicker: View {
    @Environment(\.colorScheme) private var scheme
    @State private var chosen = AppLanguage.chosen

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
                // iOS reads the choice at launch, so a change waits for the next one.
                if AppLanguage.next != AppLanguage.current {
                    Text("Close Juggle Dude and open it again to switch to \(AppLanguage.name(AppLanguage.next)).")
                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                        .accessibilityIdentifier("language-reopen")
                } else {
                    Text("Juggle Dude follows your iPhone’s language unless you pick one here.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TrainingHomeStyle.background(scheme))
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private func option<Label: View>(_ code: String?, @ViewBuilder label: () -> Label) -> some View {
        Button {
            AppLanguage.choose(code)
            chosen = code
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
