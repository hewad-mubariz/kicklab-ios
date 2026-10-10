import Combine
import Foundation

@MainActor
final class SessionHistoryStore: ObservableObject {
    @Published private(set) var items: [HistorySession] = []
    @Published private(set) var ownerID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var videoRevision = 0
    private let service: (any PlayerDataService)?
    private let queue: JugglingResultQueue
    let library: SessionHistoryLibrary
    private var generation = UUID()
    private var cursor: SessionHistoryCursor?
    private var immediateReplays: [UUID: URL] = [:]

    init(service: (any PlayerDataService)?, queue: JugglingResultQueue, library: SessionHistoryLibrary) {
        self.service = service; self.queue = queue; self.library = library
    }

    func useAccount(_ owner: UUID?) {
        generation = UUID(); ownerID = owner; items = []; cursor = nil; immediateReplays = [:]
        hasMore = false; isLoading = false; errorMessage = nil
        reloadLocal()
    }

    func reloadLocal() {
        do {
            var saved = try library.sessions(owner: ownerID)
            // Keep a newly finished session visible while its disk write runs.
            for item in items where item.syncState == .saving && !saved.contains(where: { $0.id == item.id }) {
                saved.append(item)
            }
            for request in try library.pendingRequests(owner: ownerID) {
                immediateReplays[request.item.id] = request.videoURL
            }
            if let ownerID {
                for pending in try queue.pending(for: ownerID) where !saved.contains(where: { $0.id == pending.id }) {
                    saved.append(HistorySession(result: pending))
                }
            }
            items = saved.sorted { $0.completedAt == $1.completedAt ? $0.id.uuidString > $1.id.uuidString : $0.completedAt > $1.completedAt }
        } catch { errorMessage = "Some saved sessions could not be read. Try again." }
    }

    func save(_ item: HistorySession) throws {
        try library.save(item)
        if ownerID == item.ownerID { reloadLocal() }
    }

    func showImmediately(_ item: HistorySession, videoURL: URL) {
        guard item.ownerID == ownerID else { return }
        immediateReplays[item.id] = videoURL
        var ready = item; ready.syncState = .saving
        didPersist(ready)
    }

    func didPersist(_ item: HistorySession) {
        guard item.ownerID == ownerID else { return }
        if item.syncState != .synced, items.contains(where: { $0.id == item.id && $0.syncState == .synced }) { return }
        items.removeAll { $0.id == item.id }
        items.append(item)
        items.sort { $0.completedAt == $1.completedAt ? $0.id.uuidString > $1.id.uuidString : $0.completedAt > $1.completedAt }
    }

    func replayURL(for item: HistorySession) -> URL? {
        guard item.ownerID == ownerID else { return nil }
        if let saved = library.videoURL(for: item) { return saved }
        guard let source = immediateReplays[item.id], FileManager.default.fileExists(atPath: source.path) else { return nil }
        return source
    }

    func persistenceFailed(for item: HistorySession) {
        guard item.ownerID == ownerID else { return }
        errorMessage = "This session couldn’t be saved to history. Your current replay is still available."
    }

    func videoRetained(for item: HistorySession) {
        guard item.ownerID == ownerID else { return }
        immediateReplays[item.id] = nil
        videoRevision += 1
    }

    func videoRetentionFailed(for item: HistorySession) {
        guard item.ownerID == ownerID else { return }
        errorMessage = "Your result is saved, but the replay couldn’t be kept. Check the free space on your phone."
    }

    func markSynced(_ result: SavedJugglingResult) async throws {
        // Never replace a known moderation decision with a submission receipt.
        let library = library
        let saved = try await Task.detached(priority: .utility) {
            let existing = try library.session(id: result.id, owner: result.ownerID)
            var saved = existing ?? HistorySession(result: result)
            saved.syncState = .synced
            try library.save(saved)
            return saved
        }.value
        didPersist(saved)
    }

    func retainVideo(_ url: URL, for item: HistorySession) async {
        do {
            try await library.retainVideo(url, for: item)
            videoRetained(for: item)
        } catch {
            videoRetentionFailed(for: item)
        }
    }

    func removeVideo(for item: HistorySession) {
        guard ownerID == item.ownerID else { return }
        do { try library.removeVideo(for: item); videoRevision += 1 }
        catch { errorMessage = "The replay could not be removed. Try again." }
    }

    func refresh() async {
        // A refresh supersedes an in-flight page, including its loading state.
        generation = UUID(); isLoading = false; cursor = nil; hasMore = false
        reloadLocal()
        await loadPage(before: nil)
    }

    func loadMore() async {
        guard hasMore, !isLoading, let cursor else { return }
        await loadPage(before: cursor)
    }

    private func loadPage(before: SessionHistoryCursor?) async {
        guard let owner = ownerID else { return }
        guard let service else { errorMessage = PlayerDataError.unavailable.localizedDescription; return }
        let current = generation
        isLoading = true; errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            let page = try await service.history(userID: owner, before: before)
            guard current == generation, !Task.isCancelled else { return }
            guard page.items.allSatisfy({ $0.ownerID == owner }) else { throw PlayerDataError.requestFailed }
            for item in page.items { try library.save(item) }
            cursor = page.next; hasMore = page.next != nil
            reloadLocal()
        } catch {
            if current == generation, !Task.isCancelled {
                errorMessage = "Couldn’t refresh your history. Sessions saved on this phone are still available."
            }
        }
    }
}
