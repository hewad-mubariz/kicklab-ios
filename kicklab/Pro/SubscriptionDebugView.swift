#if DEBUG
import StoreKit
import SwiftUI

/// Diagnostic output deliberately excludes descriptions, userInfo, account IDs and receipts.
enum SubscriptionDebugError {
    static func environment(_ environment: AppStore.Environment?) -> String {
        switch environment {
        case .production: "Production"
        case .sandbox: "Sandbox"
        case .xcode: "Xcode local testing"
        default: "Unknown / no verified transaction"
        }
    }

    static func describe(_ error: Error) -> String { describe(error, depth: 0) }

    private static func describe(_ error: Error, depth: Int) -> String {
        guard depth < 4 else { return "Further underlying error omitted" }
        if error is CancellationError { return "Task cancelled" }
        if let error = error as? StoreKitError {
            switch error {
            case .userCancelled: return "Apple prompt cancelled"
            case .systemError(let underlying): return "StoreKit system error → " + describe(underlying, depth: depth + 1)
            case .networkError(let underlying): return "StoreKit network error → " + describe(underlying, depth: depth + 1)
            case .notAvailableInStorefront: return "Not available in storefront"
            case .notEntitled: return "StoreKit not entitled"
            case .unsupported: return "StoreKit unsupported"
            case .unknown: return "StoreKit unknown"
            @unknown default: return "Other StoreKit error"
            }
        }
        let ns = error as NSError
        let allowedDomains = ["SKInternalErrorDomain", "SKErrorDomain", "ASDErrorDomain", "AMSErrorDomain", NSURLErrorDomain, NSCocoaErrorDomain]
        let domain = allowedDomains.contains(ns.domain) ? ns.domain : "Other error domain"
        let result = "\(domain) / \(ns.code)"
        guard let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error else { return result }
        return result + " → " + describe(underlying, depth: depth + 1)
    }
}

struct SubscriptionDebugEntry: View {
    @State private var presented = false
    var body: some View {
        Button("Subscription debug · Local build") { presented = true }
            .font(.caption.weight(.semibold))
            .foregroundStyle(ProPass.lime)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(ProPass.card)
            .accessibilityIdentifier("pro-debug-open")
            .sheet(isPresented: $presented) { SubscriptionDebugView() }
    }
}

private struct SubscriptionDebugView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var checkingApp = false
    private var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · Local Debug · D1"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Installed build") {
                    row("Build", build)
                    Text("Sandbox describes Apple’s test environment; it does not identify a TestFlight install.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Verified access now") {
                    row("Plan", subscriptions.activePlan?.title ?? "Free")
                    row("Source", subscriptions.debugAccessSource)
                    row("Purchase environment", SubscriptionDebugError.environment(subscriptions.debugEnvironment))
                    row("Apple expiry", subscriptions.localAccessUntil.map {
                        $0.formatted(date: .abbreviated, time: .standard) + " · " + TimeZone.current.identifier
                    } ?? "No active local purchase")
                    row("Juggle Dude account", subscriptions.debugAccountState)
                }
                Section("Last restore in this launch") {
                    row("Attempt", subscriptions.debugRestoreTime.map { $0.formatted(date: .omitted, time: .standard) } ?? "None")
                    Text(subscriptions.debugRestore)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("pro-debug-restore-result")
                    Text("A local diagnostic copy is saved after each attempt. No account identifiers or receipts are included.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(subscriptions.busy ? "Restoring…" : "Test Restore purchases") {
                        Task { _ = try? await subscriptions.restore() }
                    }
                    .disabled(subscriptions.busy)
                    .accessibilityIdentifier("pro-debug-restore")
                }
                Section("App transaction check") {
                    Text(subscriptions.debugAppTransaction).font(.callout.monospaced()).textSelection(.enabled)
                    Button("Check Apple app transaction") {
                        checkingApp = true
                        Task {
                            await subscriptions.checkDebugAppTransaction()
                            checkingApp = false
                        }
                    }.disabled(checkingApp || subscriptions.busy)
                    Text("Read-only check. This does not refresh purchases or grant Pro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Subscription debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }
}
#endif
