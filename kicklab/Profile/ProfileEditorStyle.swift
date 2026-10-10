import SwiftUI

struct ProfileEditorHeading: View {
    let name: String
    let subtitle: String
    var photo: Data? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MAKE IT YOURS")
                    .font(.caption2.weight(.semibold)).tracking(1.8)
                    .foregroundStyle(TrainingHomeStyle.accent(scheme))
                Text("YOUR PROFILE.")
                    .font(TrainingHomeStyle.display(38, relativeTo: .largeTitle))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.subheadline)
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            Spacer(minLength: 0)
            Group {
                if let photo, let image = UIImage(data: photo) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else { PlayerPlaceholder(name: name, size: 72) }
            }
            .frame(width: 72, height: 72).clipShape(.circle)
            .padding(6)
            .overlay { Circle().strokeBorder(TrainingHomeStyle.accent(scheme).opacity(0.25)) }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
    }
}

struct ProfileNameField: View {
    @Binding var name: String
    var maximumLength: Int? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DISPLAY NAME").font(.caption2.weight(.semibold)).tracking(1.4)
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
                Spacer()
                if let maximumLength {
                    Text("\(name.trimmingCharacters(in: .whitespacesAndNewlines).count) / \(maximumLength)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .accessibilityHidden(true)
                }
            }
            TextField("Your name", text: $name)
                .font(.title3.weight(.semibold))
                .textContentType(.nickname).textInputAutocapitalization(.words)
                .autocorrectionDisabled().submitLabel(.done)
                .accessibilityLabel("Display name")
                .accessibilityIdentifier("profile-name-field")
        }
        .padding(20)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.line(scheme)) }
    }
}

struct ProfileSaveBar: View {
    var isSaving = false
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isSaving { ProgressView().tint(TrainingHomeStyle.buttonInk) }
                Text(isSaving ? "Saving…" : "Save changes").font(.headline)
                if !isSaving { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.glassProminent).tint(TrainingHomeStyle.lime)
        .foregroundStyle(TrainingHomeStyle.buttonInk)
        .disabled(!isEnabled || isSaving)
        .accessibilityIdentifier("profile-name-save")
        .frame(maxWidth: 480)
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(TrainingHomeStyle.background(scheme).opacity(0.96))
    }
}
