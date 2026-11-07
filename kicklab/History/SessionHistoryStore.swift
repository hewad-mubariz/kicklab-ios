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
    @Published private(set) var isManagingStorage = false
    @Published private(set) var storageMessage: String?
    private let service: (any PlayerDataService)?
    private let queue: JugglingResultQueue
    let library: SessionHistoryLibrary
    private var generation = UUID()
    private var cursor: SessionHistoryCursor?
    private var immediateReplays: [UUID: URL] = [:]
    private var analysisSaves: [UUID: Task<Void, Never>] = [:]
    private var analysisSaveTokens: [UUID: UUID] = [:]

    init(service: (any PlayerDataService)?, queue: JugglingResultQueue, library: SessionHistoryLibrary) {
        self.service = service; self.queue = queue; self.library = library
    }

    func useAccount(_ owner: UUID?) {
        generation = UUID(); ownerID = owner; items = []; cursor = nil; immediateReplays = [:]
        hasMore = false; isLoading = false; errorMessage = nil
        reloadLocal()
    }

    func reloadLocal() {
        guard ProtectedAccountData.isAvailable else { return }
        do {
            try library.reconcileLocalRemovals(owner: ownerID)
            var saved = try library.sessions(owner: ownerID)
            // Keep a newly finished session visible while its disk write runs.
            for item in items where item.syncState == .saving && !library.isLocallyDeleted(id: item.id, owner: item.ownerID) && !saved.contains(where: { $0.id == item.id }) {
                saved.append(item)
            }
            for request in try library.pendingRequests(owner: ownerID) {
                immediateReplays[request.item.id] = request.videoURL
            }
            if let ownerID {
                for pending in try queue.pending(for: ownerID) where !library.isLocallyDeleted(id: pending.id, owner: ownerID) && !saved.contains(where: { $0.id == pending.id }) {
                    saved.append(HistorySession(result: pending))
                }
            }
            items = saved.sorted { $0.completedAt == $1.completedAt ? $0.id.uuidString > $1.id.uuidString : $0.completedAt > $1.completedAt }
        } catch { errorMessage = String(localized: "Some saved sessions could not be read. Try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale) }
    }

    func save(_ item: HistorySession) throws {
        try library.save(item)
        if ownerID == item.ownerID { reloadLocal() }
    }

    func showImmediately(_ item: HistorySession, videoURL: URL) {
        guard item.ownerID == ownerID, !library.isLocallyDeleted(id: item.id, owner: item.ownerID) else { return }
        immediateReplays[item.id] = videoURL
        var ready = item; ready.syncState = .saving
        didPersist(ready)
    }

    func didPersist(_ item: HistorySession) {
        guard item.ownerID == ownerID, !library.isLocallyDeleted(id: item.id, owner: ownerID) else { return }
        if item.syncState != .synced, items.contains(where: { $0.id == item.id && $0.syncState == .synced }) { return }
        items.removeAll { $0.id == item.id }
        items.append(item)
        items.sort { $0.completedAt == $1.completedAt ? $0.id.uuidString > $1.id.uuidString : $0.completedAt > $1.completedAt }
    }

    func replayURL(for item: HistorySession) -> URL? {
        guard item.ownerID == ownerID, !library.isLocallyDeleted(id: item.id, owner: ownerID) else { return nil }
        if let saved = library.videoURL(for: item) { return saved }
        guard let source = immediateReplays[item.id], FileManager.default.fileExists(atPath: source.path) else { return nil }
        return source
    }

    func persistenceFailed(for item: HistorySession) {
        guard item.ownerID == ownerID else { return }
        errorMessage = String(localized: "This session couldn’t be saved to history. Your current replay is still available.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }

    func videoRetained(for item: HistorySession) {
        guard item.ownerID == ownerID else { return }
        immediateReplays[item.id] = nil
        videoRevision += 1
    }

    func videoRetentionFailed(for item: HistorySession) {
        guard item.ownerID == ownerID else { return }
        errorMessage = String(localized: "Your result is saved, but the replay couldn’t be kept. Check the free space on your phone.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }

    func markRejected(_ result: SavedJugglingResult) async throws {
        guard !library.isLocallyDeleted(id: result.id, owner: result.ownerID) else { return }
        let library = library
        let saved = try await Task.detached(priority: .utility) {
            var saved = try library.session(id: result.id, owner: result.ownerID) ?? HistorySession(result: result)
            saved.syncState = .syncFailed
            try library.save(saved)
            return saved
        }.value
        didPersist(saved)
    }

    func markSynced(_ result: SavedJugglingResult) async throws {
        guard !library.isLocallyDeleted(id: result.id, owner: result.ownerID) else { return }
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

    @discardableResult
    func removeLocalData(for item: HistorySession, deleteSession: Bool) async -> Bool {
        guard ownerID == item.ownerID, !isManagingStorage else { return false }
        isManagingStorage = true; errorMessage = nil; storageMessage = nil
        defer { isManagingStorage = false }
        do {
            await analysisSaves[item.id]?.value
            try await VideoStorageMaintenance.run {
                guard self.ownerID == item.ownerID else { throw CancellationError() }
                try await VideoStorageMaintenance.releaseCachedResults()
                let library = self.library, files = VideoStorageFiles(library: self.library)
                let source = self.replayURL(for: item)
                try await Task.detached(priority: .utility) {
                    if let source { try files.removeTemporaryCopies(of: source) }
                    try files.clearSharedVideoCaches()
                    if deleteSession { try library.removeLocalSession(item) }
                    else { try library.removeVideo(for: item) }
                }.value
                self.immediateReplays[item.id] = nil
                self.videoRevision += 1
                self.items.removeAll { deleteSession && $0.id == item.id }
                self.reloadLocal()
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func clearStorageCache(benchmarks: Bool = false) async {
        guard !isManagingStorage else { return }
        isManagingStorage = true; errorMessage = nil; storageMessage = nil
        defer { isManagingStorage = false }
        do {
            for task in Array(analysisSaves.values) { await task.value }
            try await VideoStorageMaintenance.run {
                try await VideoStorageMaintenance.releaseCachedResults()
                let files = VideoStorageFiles(library: self.library)
                try await Task.detached(priority: .utility) {
                    if benchmarks { try files.clearBenchmarks() } else { try files.clearCaches() }
                }.value
            }
            storageMessage = String(localized: "Storage cleared. Saved sessions are still available.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeVideo(for item: HistorySession) {
        Task { await removeLocalData(for: item, deleteSession: false) }
    }

    func saveReplayEdit(_ edit: HistoryReplayEdit, id: UUID, owner: UUID?) {
        guard ownerID == owner, items.contains(where: { $0.id == id }) else { return }
        do { try library.saveReplayEdit(edit, id: id, owner: owner) }
        catch { errorMessage = String(localized: "Your latest replay edits couldn’t be saved. Check the free space on your phone.", bundle: AppLanguage.bundle, locale: AppLanguage.locale) }
    }

    /// Root-owned writes finish even when the editor closes. Mask compression
    /// and disk I/O stay off the UI thread and outside the small save journal.
    func retainReplayAnalysis(_ summary: SessionSummary, id: UUID, owner: UUID?, prepared: Bool) {
        guard ownerID == owner, let item = items.first(where: { $0.id == id }), !summary.renderTrack.isEmpty else { return }
        let previous = analysisSaves[id], library = library
        let token = UUID(); analysisSaveTokens[id] = token
        analysisSaves[id] = Task { [weak self] in
            defer {
                if self?.analysisSaveTokens[id] == token {
                    self?.analysisSaves[id] = nil; self?.analysisSaveTokens[id] = nil
                }
            }
            await previous?.value
            do {
                try await ProtectedAccountData.waitUntilAvailable()
                try await Task.detached(priority: .utility) {
                    try library.saveReplayAnalysis(.init(summary: summary, prepared: prepared), for: item)
                }.value
            } catch is CancellationError { }
            catch {
                if self?.ownerID == owner {
                    self?.errorMessage = String(localized: "Replay preparation couldn’t be saved. Check the free space on your phone.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                }
            }
        }
    }

    func waitForReplayAnalysis(id: UUID) async { await analysisSaves[id]?.value }

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
            try await ProtectedAccountData.waitUntilAvailable()
            guard current == generation, !Task.isCancelled else { return }
            for var item in page.items {
                if library.isLocallyDeleted(id: item.id, owner: owner) { continue }
                let local = try library.session(id: item.id, owner: owner)
                item.rankedProposal = item.rankedProposal ?? local?.rankedProposal
                item.touchReview = local?.touchReview
                item.touchTimesMS = local?.touchTimesMS
                try library.save(item)
            }
            cursor = page.next; hasMore = page.next != nil
            reloadLocal()
        } catch {
            if current == generation, !Task.isCancelled {
                errorMessage = String(localized: "Couldn’t refresh your history. Sessions saved on this phone are still available.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            }
        }
    }
}
