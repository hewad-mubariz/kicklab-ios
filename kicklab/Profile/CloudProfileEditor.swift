import PhotosUI
import SwiftUI

struct CloudProfilePhotoPicker: View {
    let name: String
    @EnvironmentObject private var player: PlayerStore
    @State private var item: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) { [avatarData = player.avatarData] in
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let data = avatarData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else { PlayerPlaceholder(name: name == "Player" ? "" : name, size: 88) }
                }
                .frame(width: 88, height: 88).clipShape(Circle())
                Image(systemName: "camera.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TrainingHomeStyle.buttonInk)
                    .frame(width: 28, height: 28).background(TrainingHomeStyle.lime, in: .circle)
            }
        }
        .buttonStyle(.plain)
        .disabled(player.isSaving || player.profile == nil)
        .accessibilityLabel("Change profile photo")
        .accessibilityIdentifier("profile-photo")
        .contextMenu {
            if player.profile?.avatarPath != nil {
                Button("Remove photo", systemImage: "trash", role: .destructive) {
                    Task { do { try await player.removeAvatar() } catch { self.error = error.localizedDescription } }
                }
            }
        }
        .onChange(of: item) { _, selected in
            guard let selected else { return }
            let owner = player.userID
            Task {
                defer { item = nil }
                do {
                    guard let data = try await selected.loadTransferable(type: Data.self) else { throw PlayerDataError.requestFailed }
                    let jpeg = try await Task.detached(priority: .userInitiated) { try ProfilePhoto.jpeg(data) }.value
                    guard owner == player.userID else { return }
                    try await player.uploadAvatar(jpeg)
                } catch { self.error = PlayerDataError.requestFailed.localizedDescription }
            }
        }
        .alert("Photo unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "Please try again.") }
    }
}

struct CloudProfileEditor: View {
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name: String
    @State private var country: String
    @State private var visible: Bool
    @State private var error: String?
    @State private var isSaving = false
    @State private var showsCountries = false

    init(profile: PlayerProfile) {
        _name = State(initialValue: profile.displayName)
        _country = State(initialValue: profile.countryCode ?? "")
        _visible = State(initialValue: profile.leaderboardVisible)
    }

    private var nameLength: Int { name.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var canSave: Bool { (1...40).contains(nameLength) && !player.isSaving && !isSaving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProfileEditorHeading(name: name, subtitle: "A little more you, on and off the pitch.", photo: player.avatarData)
                    ProfileNameField(name: $name, maximumLength: 40)
                    if nameLength > 40 {
                        Text("Keep your name to 40 characters.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    countryCard
                    leaderboardCard
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("profile-save-error")
                    }
                    Text("Changes are saved when you tap Save changes.")
                        .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: 480).padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .disabled(isSaving)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TrainingHomeStyle.background(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsCountries) { ProfileCountryPicker(country: $country) }
            .safeAreaInset(edge: .bottom) {
                ProfileSaveBar(isSaving: isSaving, isEnabled: canSave, action: save)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).disabled(isSaving)
                        .accessibilityIdentifier("profile-name-cancel")
                }
            }
        }
        .tint(TrainingHomeStyle.accent(scheme))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
    }

    private var countryCard: some View {
        Button { showsCountries = true } label: {
            HStack(spacing: 14) {
                Group {
                    if let selected = ProfileCountry.named(country) { Text(selected.flag).font(.title2) }
                    else { Image(systemName: "globe.europe.africa").font(.title2) }
                }
                .frame(width: 44, height: 44)
                .background(TrainingHomeStyle.accent(scheme).opacity(0.09), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("COUNTRY").font(.caption2.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                    Text(ProfileCountry.named(country)?.name ?? "Choose your country")
                        .font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.line(scheme)) }
        .accessibilityLabel("Country")
        .accessibilityValue(ProfileCountry.named(country)?.name ?? "Not selected")
        .accessibilityIdentifier("profile-country")
    }

    private var leaderboardCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $visible) {
                Label("Join the leaderboard", systemImage: "trophy")
                    .font(.body.weight(.semibold))
            }
            .tint(TrainingHomeStyle.accent(scheme))
            .accessibilityIdentifier("profile-leaderboard-visible")
            Text("Show your name, country, photo and best recorded score to other players. You can turn this off anytime.")
                .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(TrainingHomeStyle.line(scheme))
            Label("Imported videos stay private.", systemImage: "lock")
                .font(.caption).foregroundStyle(TrainingHomeStyle.muted(scheme))
        }
        .padding(20)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.line(scheme)) }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await player.updateProfile(name: name, country: country.isEmpty ? nil : country, visible: visible)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
