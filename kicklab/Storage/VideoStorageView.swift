import SwiftUI

struct VideoStorageView: View {
    @EnvironmentObject private var player: PlayerStore
    @ObservedObject var store: SessionHistoryStore
    @ObservedObject private var work = VideoBackgroundWork.shared
    @State private var snapshot: VideoStorageFiles.Snapshot?
    @State private var loading = false
    @State private var error: String?
    @State private var confirmsCache = false
    @State private var confirmsBenchmarks = false
    private var busy: Bool { loading || store.isManagingStorage || player.isManagingLocalStorage || work.isWorking }

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved sessions", value: size(snapshot?.saved))
                NavigationLink { SessionHistoryContent(store: store) } label: {
                    Label("Manage sessions", systemImage: "clock.arrow.circlepath")
                }.accessibilityIdentifier("storage-manage-sessions")
            } footer: {
                Text("Remove a replay to keep its result, or delete a session from this phone. Copies in Photos stay in Photos.")
            }
            Section {
                LabeledContent("Cached files", value: size(snapshot?.cached))
                Button("Clear cache", role: .destructive) { confirmsCache = true }
                    .disabled(busy || snapshot?.cached == 0)
                    .accessibilityIdentifier("storage-clear-cache")
            } footer: {
                Text("Clears temporary exports, duplicate imports and cached processing data. Saved videos, results and edits stay. Some data will rebuild when you edit again.")
            }
            #if DEBUG
            if (snapshot?.benchmarks ?? 0) > 0 {
                Section("Developer test files") {
                    LabeledContent("Benchmark files", value: size(snapshot?.benchmarks))
                    Button("Remove benchmark files", role: .destructive) { confirmsBenchmarks = true }
                        .disabled(busy).accessibilityIdentifier("storage-clear-benchmarks")
                }
            }
            #endif
            if loading || store.isManagingStorage || player.isManagingLocalStorage {
                Section { ProgressView("Checking storage…") }
            }
            if work.isWorking {
                Section { Text("Finish video processing before managing storage.").foregroundStyle(.secondary) }
            }
            if let message = error ?? store.errorMessage {
                Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("storage-error") }
            }
            if let message = store.storageMessage {
                Section { Text(message).accessibilityIdentifier("storage-success") }
            }
        }
        .navigationTitle("Storage").navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .alert("Clear cached files?", isPresented: $confirmsCache) {
            Button("Cancel", role: .cancel) { }
            Button("Clear cache", role: .destructive) { Task { await player.clearVideoStorageCache(); await refresh() } }
                .accessibilityIdentifier("storage-confirm-clear")
        } message: {
            Text("Saved sessions and edits will stay. Temporary files and cached processing data will be removed and rebuilt when needed.")
        }
        .alert("Remove benchmark files?", isPresented: $confirmsBenchmarks) {
            Button("Cancel", role: .cancel) { }
            Button("Remove benchmark files", role: .destructive) { Task { await player.clearVideoStorageCache(benchmarks: true); await refresh() } }
        } message: {
            Text("Removes developer test videos and reports from this app. Your session history stays.")
        }
        .accessibilityIdentifier("video-storage")
    }
    private func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }
    private func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        let files = VideoStorageFiles(library: store.library)
        do { snapshot = try await Task.detached(priority: .utility) { try files.snapshot() }.value }
        catch { self.error = error.localizedDescription }
    }
}
