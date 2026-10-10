import Combine
import Foundation
import Network
import UIKit

/// Durable per-account outbox. A guest's/device's old best is never claimed by a login.
nonisolated struct JugglingResultQueue: Sendable {
    let root: URL
    nonisolated init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("JuggleDudeResults", isDirectory: true)) { self.root = root }
    private func folder(_ owner: UUID) -> URL { root.appendingPathComponent(owner.uuidString, isDirectory: true) }
    private func path(_ result: SavedJugglingResult) -> URL { folder(result.ownerID).appendingPathComponent(result.id.uuidString + ".json") }
    func save(_ result: SavedJugglingResult) throws {
        try AccountDataGuard.write(owner: result.ownerID, root: root) {
            try FileManager.default.createDirectory(at: folder(result.ownerID), withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: path(result), options: [.atomic, .completeFileProtection])
        }
    }
    func pending(for owner: UUID) throws -> [SavedJugglingResult] {
        guard FileManager.default.fileExists(atPath: folder(owner).path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder(owner), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(SavedJugglingResult.self, from: Data(contentsOf: $0)) }
            .filter { $0.ownerID == owner }.sorted { $0.completedAt < $1.completedAt }
    }
    func remove(_ result: SavedJugglingResult) throws { try FileManager.default.removeItem(at: path(result)) }

    private var deletionFolder: URL { root.appendingPathComponent("PendingAccountDeletion", isDirectory: true) }
    func markDeleted(_ owner: UUID) throws {
        AccountDataGuard.markDeleted(owner, root: root)
        try FileManager.default.createDirectory(at: deletionFolder, withIntermediateDirectories: true)
        try Data().write(to: deletionFolder.appendingPathComponent(owner.uuidString), options: [.atomic, .completeFileProtection])
    }
    func pendingDeletions() -> [UUID] {
        ((try? FileManager.default.contentsOfDirectory(at: deletionFolder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
    }
    func finishDeletion(_ owner: UUID) throws {
        let marker = deletionFolder.appendingPathComponent(owner.uuidString)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }
    func removeAccount(_ owner: UUID) throws {
        if FileManager.default.fileExists(atPath: folder(owner).path) { try FileManager.default.removeItem(at: folder(owner)) }
    }
}

@MainActor
final class PlayerStore: ObservableObject {
    let history: SessionHistoryStore
    @Published private(set) var userID: UUID?
    @Published private(set) var profile: PlayerProfile?
    @Published private(set) var avatarData: Data?
    @Published private(set) var personalBest = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    private let service: (any PlayerDataService)?
    private let queue: JugglingResultQueue
    private var generation = UUID()
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var syncFailures = 0
    private var syncRevision = 0
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var deletedOwners = Set<UUID>()
    private let archiveVideo: @Sendable (URL, HistorySession, SessionHistoryLibrary) async throws -> Void
    private let syncRetryDelay: Duration
    private let monitor = NWPathMonitor()

    init(service: (any PlayerDataService)?, queue: JugglingResultQueue = .init(),
         syncRetryDelay: Duration = .seconds(3),
         archiveVideo: @escaping @Sendable (URL, HistorySession, SessionHistoryLibrary) async throws -> Void = {
             try await $2.retainVideo($0, for: $1)
         }) {
        self.service = service; self.queue = queue
        self.archiveVideo = archiveVideo; self.syncRetryDelay = syncRetryDelay
        history = SessionHistoryStore(service: service, queue: queue,
            library: SessionHistoryLibrary(root: queue.root.appendingPathComponent("History", isDirectory: true)))
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor [weak self] in self?.syncPending() } }
        }
        monitor.start(queue: DispatchQueue(label: "juggledude.result-sync"))
    }
    deinit { syncTask?.cancel(); retryTask?.cancel(); monitor.cancel() }

    static func live(account: AccountStore) -> PlayerStore {
        #if DEBUG
        if SessionHistoryReview.requested { return SessionHistoryReview.store() }
        #endif
        guard let config = try? AccountConfiguration.load() else { return PlayerStore(service: nil) }
        return PlayerStore(service: SupabasePlayerService(config: config) { [weak account] id in
            guard let account else { throw PlayerDataError.signIn }
            return try await account.accessToken(for: id)
        })
    }

    func useAccount(_ identity: AccountIdentity?) async {
        for owner in queue.pendingDeletions() { _ = await removeDeletedAccountData(owner) }
        let identity = identity.flatMap { deletedOwners.contains($0.id) ? nil : $0 }
        generation = UUID()
        syncTask?.cancel(); syncTask = nil
        retryTask?.cancel(); retryTask = nil; syncFailures = 0
        userID = identity?.id; profile = nil; avatarData = nil; pendingCount = 0; personalBest = 0
        errorMessage = nil; isSaving = false
        history.useAccount(identity?.id)
        await refresh()
    }

    /// Drain old writes before removing files so an in-flight copy/upload cannot
    /// recreate history after deletion. The durable marker retries interrupted cleanup.
    @discardableResult
    func removeDeletedAccountData(_ owner: UUID) async -> Bool {
        deletedOwners.insert(owner)
        try? queue.markDeleted(owner)
        let activeSync = userID == owner ? syncTask : nil
        activeSync?.cancel()
        let saves = saveTasks.filter { $0.key.hasPrefix(owner.uuidString + "/") }.map(\.value)
        saves.forEach { $0.cancel() }
        if userID == owner {
            generation = UUID(); syncTask = nil
            retryTask?.cancel(); retryTask = nil
            userID = nil; profile = nil; avatarData = nil; personalBest = 0; pendingCount = 0
            isSaving = false; errorMessage = nil
            history.useAccount(nil)
        }
        await activeSync?.value
        for task in saves { await task.value }
        let queue = queue, library = history.library
        do {
            try await Task.detached(priority: .utility) {
                try queue.removeAccount(owner)
                try library.removeAccount(owner)
                try queue.finishDeletion(owner)
            }.value
            return true
        } catch { return false }
    }

    func refresh() async {
        await resumeSaves()
        syncPending()
        guard let id = userID, let service else { return }
        let current = generation
        do {
            async let best = service.personalBest(userID: id)
            let loaded = try await service.profile(userID: id)
            let loadedBest = try await best
            guard current == generation, !Task.isCancelled else { return }
            profile = loaded
            personalBest = max(loadedBest, (try? queue.pending(for: id).map(\.touches).max()) ?? 0)
            await loadAvatar(loaded, generation: current)
        } catch {
            if current == generation, !Task.isCancelled { errorMessage = PlayerDataError.requestFailed.localizedDescription }
        }
        if current == generation { syncPending() }
    }

    func updateProfile(name: String, country: String?, visible: Bool) async throws {
        guard var updated = profile, updated.id == userID, let service else { throw PlayerDataError.signIn }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(trimmed.count), country == nil || country?.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw PlayerDataError.invalidProfile
        }
        updated.displayName = trimmed; updated.countryCode = country; updated.leaderboardVisible = visible
        let current = generation
        isSaving = true
        defer { if current == generation { isSaving = false } }
        let saved = try await service.saveProfile(updated)
        guard current == generation else { throw CancellationError() }
        profile = saved; errorMessage = nil
    }

    func uploadAvatar(_ jpeg: Data) async throws {
        guard var updated = profile, updated.id == userID, let service, !isSaving else { throw PlayerDataError.signIn }
        let current = generation
        isSaving = true
        defer { if current == generation { isSaving = false } }
        try await service.uploadAvatar(jpeg, userID: updated.id)
        guard current == generation else { throw CancellationError() }
        updated.avatarPath = updated.id.uuidString.lowercased() + "/avatar.jpg"
        let saved = try await service.saveProfile(updated)
        guard current == generation else { throw CancellationError() }
        profile = saved; avatarData = jpeg; errorMessage = nil
    }

    func removeAvatar() async throws {
        guard var updated = profile, updated.id == userID, let service, !isSaving else { throw PlayerDataError.signIn }
        let current = generation
        isSaving = true
        defer { if current == generation { isSaving = false } }
        try await service.deleteAvatar(userID: updated.id)
        guard current == generation else { throw CancellationError() }
        updated.avatarPath = nil
        let saved = try await service.saveProfile(updated)
        guard current == generation else { throw CancellationError() }
        profile = saved; avatarData = nil; errorMessage = nil
    }

    func record(_ result: SavedJugglingResult) {
        guard !deletedOwners.contains(result.ownerID) else { return }
        do {
            try queue.save(result)
            // Keep history after the outbox is removed on a successful upload.
            try history.save(HistorySession(result: result))
            if result.ownerID == userID {
                personalBest = max(personalBest, result.touches)
                pendingCount = try queue.pending(for: result.ownerID).count
                syncPending()
            }
        } catch { errorMessage = "The session could not be queued for your account. Your video is still available on this device." }
    }

    /// Returns immediately. The root-owned task keeps only metadata and a URL,
    /// never the session's analysis buffers, and outlives the capture/editor view.
    @discardableResult
    func recordSession(id: UUID, owner: UUID?, summary: SessionSummary,
                       source: SavedJugglingResult.Source, completedAt: Date) -> Task<Void, Never>? {
        if let owner, deletedOwners.contains(owner) { return nil }
        guard (0...1_000_000).contains(summary.touches), summary.duration.isFinite,
              summary.duration > 0, summary.duration <= 86400 else {
            errorMessage = PlayerDataError.invalidResult.localizedDescription; return nil
        }
        let item: HistorySession
        do {
            let result: SavedJugglingResult?
            if let owner {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                let saved = try SavedJugglingResult(id: id, ownerID: owner, touches: summary.touches,
                    duration: summary.duration, source: source, completedAt: completedAt, appVersion: version)
                result = saved
                item = HistorySession(result: saved)
            } else {
                item = HistorySession(id: id, ownerID: nil, touches: summary.touches,
                    durationMS: max(1, Int((summary.duration * 1000).rounded())), source: source,
                    completedAt: completedAt, syncState: .deviceOnly)
                result = nil
            }
            let request = SessionSaveRequest(item: item, result: result, videoURL: summary.videoURL)
            if let task = saveTasks[request.key] { return task }
            history.showImmediately(item, videoURL: summary.videoURL)
            if owner == userID { personalBest = max(personalBest, item.touches) }
            return startSave(request)
        } catch { errorMessage = "This session could not be saved to history. Your current replay is still available."; return nil }
    }

    private func startSave(_ request: SessionSaveRequest) -> Task<Void, Never> {
        if let owner = request.item.ownerID, deletedOwners.contains(owner) { return Task {} }
        if let task = saveTasks[request.key] { return task }
        let library = history.library, queue = queue, archiveVideo = archiveVideo
        let activity = SessionSaveActivity()
        let task = Task { [self] in
            defer { saveTasks[request.key] = nil; activity.finish() }
            do {
                let saved = try await Task.detached(priority: .utility) {
                    try request.persist(library: library, queue: queue)
                }.value
                try Task.checkCancellation()
                history.didPersist(saved)
                if request.item.ownerID == userID { syncPending() }
            } catch {
                history.persistenceFailed(for: request.item)
                return
            }
            // The cloud request and the video copy are independent. Neither
            // owns the preview's lifetime or gates its presentation.
            do {
                try Task.checkCancellation()
                try await archiveVideo(request.videoURL, request.item, library)
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) { try library.finishRequest(request.item) }.value
                history.videoRetained(for: request.item)
            } catch { history.videoRetentionFailed(for: request.item) }
        }
        saveTasks[request.key] = task
        return task
    }

    private func resumeSaves() async {
        let owner = userID, current = generation, library = history.library
        let requests = (try? await Task.detached(priority: .utility) {
            try library.pendingRequests(owner: owner)
        }.value) ?? []
        guard current == generation else { return }
        for request in requests where saveTasks[request.key] == nil { _ = startSave(request) }
    }

    func syncPending() {
        syncRevision &+= 1
        retryTask?.cancel(); retryTask = nil
        guard syncTask == nil, let owner = userID, let service else { return }
        let current = generation
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == current { self.syncTask = nil } }
            let queue = self.queue
            while !Task.isCancelled, self.generation == current {
                do {
                    let revision = self.syncRevision
                    let pending = try await Task.detached(priority: .utility) { try queue.pending(for: owner) }.value
                    guard !Task.isCancelled, self.generation == current else { return }
                    self.pendingCount = pending.count
                    guard let result = pending.first else {
                        if revision != self.syncRevision { continue }
                        return
                    }
                    try await service.submit(result)
                    guard !Task.isCancelled, !self.deletedOwners.contains(owner) else { return }
                    try await self.history.markSynced(result)
                    // A late success still removes only its original account's outbox item.
                    try await Task.detached(priority: .utility) { try queue.remove(result) }.value
                    guard self.generation == current else { return }
                    self.syncFailures = 0
                } catch {
                    guard !Task.isCancelled, self.generation == current else { return }
                    // Transient connectivity is routine. Keep the durable result
                    // and retry quietly, with bounded backoff, while the app runs.
                    self.syncFailures = min(self.syncFailures + 1, 7)
                    let delay = min(self.syncRetryDelay * (1 << (self.syncFailures - 1)), .seconds(180))
                    self.retryTask = Task { [weak self] in
                        do { try await Task.sleep(for: delay) } catch { return }
                        guard let self, self.generation == current else { return }
                        self.syncPending()
                    }
                    return
                }
            }
        }
    }

    func leaderboard(period: LeaderboardPeriod) async throws -> (entries: [LeaderboardEntry], around: [LeaderboardEntry]) {
        guard let service else { throw PlayerDataError.unavailable }
        let owner = userID
        let board = try await service.leaderboard(period: period == .week ? "week" : "all_time", country: nil, userID: owner)
        let all = board.entries + board.aroundMe.filter { row in !board.entries.contains { $0.userID == row.userID } }
        let urls = await withTaskGroup(of: (UUID, URL?).self, returning: [UUID: URL].self) { group in
            for row in all {
                guard let path = row.avatarPath else { continue }
                group.addTask { (row.userID, try? await service.avatarURL(path: path, userID: owner)) }
            }
            var result: [UUID: URL] = [:]
            for await (id, url) in group { if let url { result[id] = url } }
            return result
        }
        try Task.checkCancellation()
        func entry(_ row: RankedPlayer) -> LeaderboardEntry {
            LeaderboardEntry(rank: row.rank, name: row.displayName, touches: row.touches,
                isYou: row.isYou, photo: urls[row.userID])
        }
        return (board.entries.map(entry), board.aroundMe.map(entry))
    }

    private func loadAvatar(_ profile: PlayerProfile, generation current: UUID) async {
        guard let path = profile.avatarPath, let service else { avatarData = nil; return }
        do {
            let url = try await service.avatarURL(path: path, userID: profile.id)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2_097_152 else { return }
            if current == generation, !Task.isCancelled { avatarData = data }
        } catch { /* A missing photo never blocks account access or result sync. */ }
    }
}

/// iOS grants a short grace period on backgrounding; the journal survives if
/// that time expires. No promise of unlimited execution after force-quit.
@MainActor
private final class SessionSaveActivity {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Keep session replay") { [weak self] in
            Task { @MainActor in self?.finish() }
        }
    }
    func finish() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}
