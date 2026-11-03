import SwiftUI

/// Keep the tray compact; the system dialog keeps text entry above the keyboard.
/// A draft avoids redrawing all twelve counter thumbnails on every keystroke.
struct CounterLabelField: View {
    @Binding var item: ExportOverlayItem
    @State private var editing = false
    @State private var draft = ""

    private var label: String { CounterLabel.display(item.customLabel) }
    private var isCustom: Bool { CounterLabel.saved(item.customLabel ?? "") != nil }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: beginEditing) {
                HStack(spacing: 10) {
                    Image(systemName: "textformat")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.1), in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Counter text").font(.system(size: 13, weight: .semibold))
                        Text(verbatim: label)
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Label("Edit", systemImage: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(minHeight: 34)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Counter text")
            .accessibilityValue(label)
            .accessibilityHint("Edit counter text")
            .accessibilityIdentifier("counter-text-edit")

            if isCustom {
                Button("Reset") { item.customLabel = nil }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minHeight: 34)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("counter-text-reset")
            }
        }
        // Same content height, inset and border as the Milestones row.
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("counter-text-row")
        .alert("Counter text", isPresented: $editing) {
            TextField("Touches", text: Binding(
                get: { draft }, set: { draft = CounterLabel.editable($0) }
            ))
            .textInputAutocapitalization(.sentences).autocorrectionDisabled()
            .accessibilityIdentifier("counter-text")
            Button("Cancel", role: .cancel) {}
            Button("Save") { item.customLabel = CounterLabel.saved(draft) }
                .accessibilityIdentifier("counter-text-save")
        } message: {
            Text("Change the label shown on your counter.")
        }
        .tint(.primary)
    }

    private func beginEditing() {
        draft = label
        editing = true
    }
}
