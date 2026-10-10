import SwiftUI

struct TrainingProfileView: View {
    let personalBest: Int
    @Binding var appearance: String
    /// Leaves Profile for the main sign-in view.
    var onSignIn: () -> Void = {}
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerStore
    @AppStorage("kicklab.profile.displayName") private var displayName = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var editsName = false
    @State private var confirmsDeletion = false
    @Environment(\.openURL) private var openURL

    private var name: String {
        if account.user != nil { return player.profile?.displayName ?? "Your profile" }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your profile" : trimmed
    }

    private var initials: String {
        (account.user == nil ? displayName : (account.user?.name ?? "")).split(whereSeparator: \.isWhitespace).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    identity
                    if let user = account.user {
                        VStack(spacing: 14) {
                            Label("Signed in", systemImage: "checkmark.seal")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(TrainingHomeStyle.accent(scheme))
                            if let email = user.email {
                                Text(email).font(.subheadline).textSelection(.enabled)
                                    .accessibilityIdentifier("profile-account-email")
                            }
                            Button("Sign out") { Task { await account.signOut() } }
                                .buttonStyle(.glass).disabled(account.isBusy)
                                .accessibilityIdentifier("profile-sign-out")
                        }
                    } else { signInEntry }
                    AccountErrorBanner()
                    if account.user != nil {
                        VStack(spacing: 8) {
                            if let error = player.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                            if player.errorMessage != nil {
                                Button("Retry sync") { Task { await player.refresh() } }.buttonStyle(.glass)
                            }
                        }
                    }
                    ProProfileCard()
                    record
                    NavigationLink {
                        SessionHistoryContent(store: player.history)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).frame(width: 28)
                            Text("Session history").font(.body.weight(.medium))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .padding(20)
                        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
                        .contentShape(.rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("profile-session-history")
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
                    if account.user != nil { deleteAccountSection }
                }
                .frame(maxWidth: 480)
                .padding(24)
                .frame(maxWidth: .infinity)
                .disabled(account.isDeleting)
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
                        .disabled(account.isDeleting)
                }
            }
            .sheet(isPresented: $editsName) {
                if account.user != nil, let profile = player.profile {
                    CloudProfileEditor(profile: profile)
                } else { TrainingProfileNameEditor(name: $displayName) }
            }
            .alert("Delete your account?", isPresented: $confirmsDeletion) {
                Button("Cancel", role: .cancel) { }
                Button("Delete account", role: .destructive) {
                    Task {
                        if await account.deleteAccount(cleanup: { await player.removeDeletedAccountData($0) }) {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This permanently removes your account, profile photo, saved results and this account’s local replays. You’ll be signed out. Clips exported to Photos and guest sessions stay on this phone. Apple subscriptions must be cancelled separately.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(account.isDeleting)
        .id(account.user?.id)
    }

    private var deleteAccountSection: some View {
        VStack(spacing: 8) {
            Button(role: .destructive) { confirmsDeletion = true } label: {
                HStack(spacing: 8) {
                    if account.isDeleting { ProgressView() }
                    Text(account.isDeleting ? "Deleting account…" : "Delete account")
                }
                .frame(minHeight: 44)
            }
            .disabled(account.isBusy || player.isSaving)
            .accessibilityIdentifier("profile-delete-account")
            Text("Deleting your account doesn’t cancel an Apple subscription.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Manage Apple subscriptions") {
                openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
            .font(.footnote).frame(minHeight: 44)
            .accessibilityIdentifier("profile-manage-subscriptions")
        }
    }

    private var signInEntry: some View {
        Button(action: onSignIn) {
            HStack(spacing: 14) {
                ProfileMonolineMark().frame(width: 27, height: 27)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Sign in to Juggle Dude").font(.body.weight(.semibold))
                    Text("Apple, Google or email")
                        .font(.caption).foregroundStyle(TrainingHomeStyle.muted(scheme))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TrainingHomeStyle.accent(scheme).opacity(scheme == .dark ? 0.07 : 0.06), in: .rect(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.accent(scheme).opacity(0.18)) }
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile-sign-in")
    }

    private var identity: some View {
        VStack(spacing: 14) {
            // Your picture also shows on the leaderboard; without one, these initials do.
            if account.user != nil {
                CloudProfilePhotoPicker(name: name)
            } else { ProfilePhotoPicker(size: 88) {
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
            }
            }

            Text(name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("profile-name")
                .accessibilityAddTraits(.isHeader)

            Button(account.user == nil ? "Edit name" : "Edit profile", systemImage: "pencil") { editsName = true }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.glass)
                .disabled(account.user != nil && player.profile == nil)
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
    @Environment(\.colorScheme) private var scheme

    init(name: Binding<String>) {
        _name = name
        _draft = State(initialValue: name.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProfileEditorHeading(name: draft, subtitle: "A little more you, on and off the pitch.")
                    ProfileNameField(name: $draft).onSubmit(save)
                    Text("Your name is saved on this device.")
                        .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: 480).padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TrainingHomeStyle.background(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .navigationTitle("Edit name")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { ProfileSaveBar(action: save) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("profile-name-cancel")
                }
            }
        }
        .tint(TrainingHomeStyle.accent(scheme))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}
