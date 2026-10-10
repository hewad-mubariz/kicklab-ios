import SwiftUI

struct AccountErrorBanner: View {
    @EnvironmentObject private var account: AccountStore
    var body: some View {
        if let message = account.errorMessage {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account-error")
                Spacer(minLength: 0)
                Button("Dismiss message", systemImage: "xmark") { account.errorMessage = nil }
                    .labelStyle(.iconOnly)
            }
            .padding(16).foregroundStyle(.primary)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
        }
    }
}
