import SwiftUI

struct ProfileCountry: Identifiable {
    let id: String
    let name: String

    var flag: String {
        String(String.UnicodeScalarView(id.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }

    // Build the localized, stably identified choices once, rather than rebuilding
    // a large system Picker menu whenever account sync publishes a change.
    static let all: [ProfileCountry] = Locale.Region.isoRegions.compactMap { region in
        let code = region.identifier
        guard code.utf8.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }),
              let name = Locale.current.localizedString(forRegionCode: code) else { return nil }
        return ProfileCountry(id: code, name: name)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static func named(_ code: String) -> ProfileCountry? { all.first { $0.id == code } }
}

/// Owns search and scroll state, and intentionally does not observe PlayerStore.
struct ProfileCountryPicker: View {
    @Binding var country: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    private var filtered: [ProfileCountry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ProfileCountry.all }
        return ProfileCountry.all.filter {
            $0.name.localizedStandardContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    row(code: "", name: "Not selected", flag: nil)
                        .id("")
                }
                ForEach(filtered) { item in
                    row(code: item.id, name: item.name, flag: item.flag)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
            .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("profile-country-list")
        .overlay {
            if filtered.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .navigationTitle("Country").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search countries")
        .onChange(of: search) { _, _ in scrollPosition.scrollTo(edge: .top) }
    }

    private func row(code: String, name: String, flag: String?) -> some View {
        Button {
            country = code
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let flag { Text(flag).font(.title2) }
                    else { Image(systemName: "globe").font(.title3).foregroundStyle(TrainingHomeStyle.muted(scheme)) }
                }
                .frame(width: 36, height: 36)
                Text(name).font(.body.weight(country == code ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if country == code {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).foregroundStyle(TrainingHomeStyle.accent(scheme))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(minHeight: 60)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(TrainingHomeStyle.line(scheme).opacity(0.65)).frame(height: 0.5).padding(.leading, 68) }
        .accessibilityLabel(name)
        .accessibilityAddTraits(country == code ? .isSelected : [])
        .accessibilityIdentifier("country-option-\(code.isEmpty ? "none" : code)")
    }
}
