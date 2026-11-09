import AppTrackingTransparency
import SwiftUI
import UIKit

struct TrainingHomeSettings: View {
    @Binding var appearance: String
    @EnvironmentObject private var player: PlayerStore
    @ObservedObject private var analytics = ProductAnalytics.shared
    @ObservedObject private var updates = AppUpdateNotice.shared
    @ObservedObject private var adMeasurement = MetaAdsMeasurement.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    #if DEBUG
    @AppStorage(DebugOverlayPreferences.visibilityKey) private var showDebugOverlays = DebugOverlayPreferences.visibleByDefault
    #endif

    var body: some View {
        Form {
            if let release = updates.available {
                // First in the list, and stays after the update alert is dismissed, until the update is installed.
                Section {
                    Button { openURL(AppUpdateNotice.appStoreURL) } label: {
                        LabeledContent {
                            Text(String(localized: "Version \(release.version)", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
                        } label: {
                            SettingsLabel("Update available", symbol: "arrow.down.circle")
                        }
                    }
                    .accessibilityIdentifier("settings-app-update")
                }
                .listRowBackground(TrainingHomeStyle.panel(scheme))
            }
            Section("Appearance") {
                AppearanceChooser(appearance: $appearance)
                    .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
            }
            .listRowBackground(TrainingHomeStyle.panel(scheme))
            Section("General") {
                NavigationLink { AppLanguagePicker() } label: {
                    LabeledContent { Text(AppLanguage.name(AppLanguage.current)) } label: {
                        SettingsLabel("Language", symbol: "globe")
                    }
                }
                .accessibilityIdentifier("settings-language")
                NavigationLink { VideoStorageView(store: player.history) } label: {
                    SettingsLabel("Storage", symbol: "internaldrive")
                }.accessibilityIdentifier("settings-storage")
                NavigationLink { NotificationSettingsView() } label: {
                    SettingsLabel("Notifications", symbol: "bell.badge")
                }.accessibilityIdentifier("settings-notifications")
            }
            .listRowBackground(TrainingHomeStyle.panel(scheme))
            Section {
                Toggle(isOn: Binding(get: { analytics.isEnabled }, set: { analytics.setEnabled($0) })) {
                    SettingsLabel("Share usage analytics", symbol: "chart.bar.xaxis")
                }
                .accessibilityIdentifier("analytics-sharing")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Help improve Juggle Dude by sharing feature usage and whether actions succeed. Uses a random installation ID. Your videos, email and sign-in details aren’t included. You can turn this off anytime.")
            }
            .listRowBackground(TrainingHomeStyle.panel(scheme))
            if adMeasurement.isAvailable {
                Section {
                    LabeledContent { Text(adPermissionLabel) } label: {
                        SettingsLabel("Tracking permission", symbol: "hand.raised")
                    }
                    if adMeasurement.authorizationStatus == .notDetermined {
                        Button("Choose tracking permission") {
                            Task { await adMeasurement.requestPermission() }
                        }
                        .disabled(adMeasurement.isRequesting)
                        .accessibilityIdentifier("meta-ad-permission")
                    } else {
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .accessibilityIdentifier("meta-ad-settings")
                    }
                    Link("Privacy Policy", destination: LegalLinks.privacy)
                } header: {
                    Text("Advertising measurement")
                } footer: {
                    Text("Meta measures our Facebook and Instagram ads using app installs and opens, first-session completion, and Pro trial or subscription starts. With tracking allowed, your advertising identifier is included. In the EEA, UK and Switzerland, nothing is sent without permission. Elsewhere, events without that identifier can still be sent. Videos, touch counts and account details aren’t included.")
                }
                .listRowBackground(TrainingHomeStyle.panel(scheme))
            }
            #if DEBUG
            Section {
                Toggle(isOn: $showDebugOverlays) { SettingsLabel("Show debug overlays", symbol: "ladybug") }
                    .accessibilityIdentifier("settings-debug-overlays")
            } header: {
                Text("Developer")
            } footer: {
                Text("Show memory, thermal state and touch/body diagnostics. Close the debug panel to hide them everywhere. This setting is only available in local debug builds.")
            }
            .listRowBackground(TrainingHomeStyle.panel(scheme))
            #endif
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Section {} footer: { about(version) }
            }
        }
        .tint(TrainingHomeStyle.accent(scheme))
        .scrollContentBackground(.hidden)
        .background(TrainingHomeStyle.background(scheme))
        .navigationTitle(String(localized: "Settings", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The app's name and build at the foot of the list, where About rows used to sit.
    private func about(_ version: String) -> some View {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return VStack(spacing: 4) {
            Text(verbatim: "JUGGLE DUDE")
                .font(TrainingHomeStyle.display(20, relativeTo: .headline)).tracking(1.2)
                .foregroundStyle(TrainingHomeStyle.ink(scheme))
            Text(String(localized: "Version \(version)", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                 + (build.map { " (\($0))" } ?? ""))
                .font(.footnote).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-version")
    }

    private var adPermissionLabel: String {
        switch adMeasurement.authorizationStatus {
        case .authorized: String(localized: "Allowed", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .denied: String(localized: "Not allowed", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .restricted: String(localized: "Restricted on this device", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .notDetermined: String(localized: "Not chosen", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        @unknown default: String(localized: "Not allowed", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
}

/// A settings row title beside a plain accent icon in a fixed-width slot, so every row lines up.
private struct SettingsLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    @Environment(\.colorScheme) private var scheme

    init(_ title: LocalizedStringKey, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(TrainingHomeStyle.accent(scheme))
                .frame(width: 30, height: 30)
        }
    }
}

/// System, Light and Dark as small home screens, so each choice shows what it does.
private struct AppearanceChooser: View {
    @Binding var appearance: String
    @Environment(\.colorScheme) private var scheme
    private let options: [(value: String, title: LocalizedStringKey)] = [("system", "System"), ("light", "Light"), ("dark", "Dark")]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { option in
                let selected = appearance == option.value
                Button { appearance = option.value } label: {
                    VStack(spacing: 8) {
                        AppearanceThumbnail(value: option.value)
                            .frame(height: 76)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selected ? TrainingHomeStyle.accent(scheme) : TrainingHomeStyle.line(scheme),
                                                  lineWidth: selected ? 2.5 : 1)
                            }
                        HStack(spacing: 5) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? TrainingHomeStyle.accent(scheme) : TrainingHomeStyle.muted(scheme))
                                .contentTransition(.symbolEffect(.replace))
                            Text(option.title).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                // Plain buttons, so a tap in this one Form row only picks its own choice.
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("appearance-\(option.value)")
            }
        }
        .animation(.snappy(duration: 0.25), value: appearance)
        .sensoryFeedback(.selection, trigger: appearance)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance-picker")
    }
}

/// A miniature home screen in one appearance; System shows light and dark split corner to corner.
private struct AppearanceThumbnail: View {
    let value: String

    var body: some View {
        ZStack {
            if value != "dark" { screen(.light) }
            if value != "light" { screen(.dark).mask { value == "dark" ? AnyShape(Rectangle()) : AnyShape(LowerTriangle()) } }
        }
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private func screen(_ scheme: ColorScheme) -> some View {
        TrainingHomeStyle.background(scheme).overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(TrainingHomeStyle.ink(scheme)).frame(width: 28, height: 5)
                RoundedRectangle(cornerRadius: 6).fill(TrainingHomeStyle.panel(scheme))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(TrainingHomeStyle.line(scheme), lineWidth: 0.5) }
                    .frame(height: 24)
                Capsule().fill(TrainingHomeStyle.lime).frame(height: 11)
            }
            .padding(10)
        }
    }
}

private struct LowerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct TrainingCameraGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                step("iphone.gen3", title: "Prop up your phone",
                     detail: "Rest it on a stable surface or tripod, with the camera facing you. Keep it still while you train.")
                step("viewfinder", title: "Give yourself room",
                     detail: "Step back until your whole body and the ball fit in the preview. Leave space above your head and around your feet for the ball to move.")
                step("sun.max", title: "Keep the ball easy to see",
                     detail: "Choose a bright spot with light in front of you, rather than behind you. A clear background helps the camera follow the ball.")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Continue") { dismiss() }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(TrainingHomeStyle.buttonInk)
                .background(TrainingHomeStyle.lime, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-guide-done")
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(TrainingHomeStyle.background(scheme))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func step(_ icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 25))
                .foregroundStyle(TrainingHomeStyle.accent(scheme))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(detail).font(.subheadline)
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
