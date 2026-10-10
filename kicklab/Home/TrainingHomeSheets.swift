import SwiftUI

struct TrainingHomeSettings: View {
    @Binding var appearance: String
    @ObservedObject private var analytics = ProductAnalytics.shared
    @Environment(\.colorScheme) private var scheme

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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    step("iphone.gen3", title: "Prop up your phone",
                         detail: "Use a stable surface or tripod to keep the camera steady.")
                    step("viewfinder", title: "Leave room to move",
                         detail: "Keep your whole body and the ball in view, with space around your feet.")
                    step("sun.max", title: "Find a well-lit spot",
                         detail: "Good light and a clear background help the camera follow the ball.")
                    Button("Got it") { dismiss() }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(TrainingHomeStyle.buttonInk)
                        .background(TrainingHomeStyle.lime, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("home-guide-done")
                }
                .padding(24)
            }
            .background(TrainingHomeStyle.background(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .navigationTitle("Camera setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
                Text(title).font(.headline)
                Text(detail).font(.subheadline)
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
        }
    }
}
