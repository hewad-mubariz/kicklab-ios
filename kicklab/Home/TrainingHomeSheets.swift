import SwiftUI

struct TrainingHomeSettings: View {
    @Binding var appearance: String
    @ObservedObject private var analytics = ProductAnalytics.shared
    @Environment(\.colorScheme) private var scheme
    #if DEBUG
    @AppStorage(DebugOverlayPreferences.visibilityKey) private var showDebugOverlays = DebugOverlayPreferences.visibleByDefault
    #endif

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-picker")
            }
            Section {
                Toggle("Share usage analytics", isOn: Binding(
                    get: { analytics.isEnabled }, set: { analytics.setEnabled($0) }))
                    .accessibilityIdentifier("analytics-sharing")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Help improve Juggle Dude by sharing feature usage and whether actions succeed. Uses a random installation ID. Your videos, email and sign-in details aren’t included. You can turn this off anytime.")
            }
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Section("About") {
                    LabeledContent("Juggle Dude", value: "Version \(version)")
                }
            }
            #if DEBUG
            Section {
                Toggle("Show debug overlays", isOn: $showDebugOverlays)
                    .accessibilityIdentifier("settings-debug-overlays")
            } header: {
                Text("Developer")
            } footer: {
                Text("Show memory, thermal state and touch/body diagnostics. Close the debug panel to hide them everywhere. This setting is only available in local debug builds.")
            }
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(TrainingHomeStyle.background(scheme))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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

    private func step(_ icon: String, title: String, detail: String) -> some View {
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
