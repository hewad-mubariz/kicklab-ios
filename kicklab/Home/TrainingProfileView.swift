import SwiftUI

struct TrainingProfileView: View {
    let personalBest: Int
    @Binding var appearance: String
    @AppStorage("kicklab.profile.displayName") private var displayName = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var editsName = false

    private var name: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your profile" : trimmed
    }

    private var initials: String {
        displayName.split(whereSeparator: \.isWhitespace).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    identity
                    record
                    NavigationLink {
                        TrainingHomeSettings(appearance: $appearance)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 22))
                                .frame(width: 28)
                            Text("Settings").font(.body.weight(.medium))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(TrainingHomeStyle.muted(scheme))
                        }
                        .padding(20)
                        .background(TrainingHomeStyle.panel(scheme), in: RoundedRectangle(cornerRadius: 22))
                        .contentShape(RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile-settings")
                }
                .frame(maxWidth: 480)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.background(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close profile", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("profile-close")
                }
            }
            .sheet(isPresented: $editsName) {
                TrainingProfileNameEditor(name: $displayName)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var identity: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(TrainingHomeStyle.accent(scheme).opacity(0.12))
                Circle().strokeBorder(TrainingHomeStyle.accent(scheme).opacity(0.3))
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: 36, weight: .medium))
                } else {
                    Text(initials).font(.system(size: 30, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5).padding(12)
                }
            }
            .foregroundStyle(TrainingHomeStyle.accent(scheme))
            .frame(width: 88, height: 88)
            .accessibilityHidden(true)

            Text(name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("profile-name")
                .accessibilityAddTraits(.isHeader)

            Button("Edit name", systemImage: "pencil") { editsName = true }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.glass)
                .accessibilityIdentifier("profile-edit-name")
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var record: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("PERSONAL BEST", systemImage: "trophy")
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(TrainingHomeStyle.accent(scheme))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(personalBest > 0 ? personalBest.formatted() : "—")
                    .font(TrainingHomeStyle.display(60, relativeTo: .largeTitle))
                Text("touches")
                    .font(.callout)
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            Text(personalBest > 0 ? "Juggling" : "Your first juggling session starts your record.")
                .font(.subheadline)
                .foregroundStyle(TrainingHomeStyle.muted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(TrainingHomeStyle.panel(scheme), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(TrainingHomeStyle.line(scheme)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(personalBest > 0
            ? "Juggling personal best, \(personalBest) touches"
            : "Juggling personal best. Your first juggling session starts your record.")
        .accessibilityIdentifier("profile-personal-best")
    }
}

private struct TrainingProfileNameEditor: View {
    @Binding var name: String
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    init(name: Binding<String>) {
        _name = name
        _draft = State(initialValue: name.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $draft)
                        .textContentType(.nickname)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isFocused)
                        .onSubmit(save)
                        .accessibilityIdentifier("profile-name-field")
                } footer: {
                    Text("Your name is saved on this device.")
                }
            }
            .navigationTitle("Edit name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("profile-name-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .accessibilityIdentifier("profile-name-save")
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}
