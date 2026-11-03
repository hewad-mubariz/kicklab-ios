import SwiftUI

struct CounterLabelField: View {
    @Binding var item: ExportOverlayItem
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Counter text").font(.system(size: 13, weight: .semibold))
                TextField("Touches", text: Binding(
                    get: { item.customLabel ?? CounterLabel.defaultText },
                    set: { item.customLabel = CounterLabel.editable($0) }
                ))
                .font(.system(size: 15))
                .frame(minHeight: 24)
                .foregroundStyle(.white.opacity(0.8)).tint(.white)
                .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                .submitLabel(.done).focused($focused)
                .onSubmit { focused = false }
                .accessibilityLabel("Counter text")
                .accessibilityIdentifier("counter-text")
            }
            Button("Reset") { item.customLabel = nil; focused = false }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(item.customLabel == nil ? 0.35 : 0.85))
                .frame(minHeight: 44)
                .disabled(item.customLabel == nil)
                .accessibilityIdentifier("counter-text-reset")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(focused ? 0.5 : 0.16), lineWidth: 0.75)
        }
    }
}
