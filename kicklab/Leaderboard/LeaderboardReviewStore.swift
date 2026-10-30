import Combine
import Foundation

/// A submission the player confirmed, kept on this phone until it is sent.
nonisolated struct QueuedLeaderboardSubmission: Codable, Equatable, Sendable {
    let sessionID: UUID
    let proposal: RankedStreakProposal
    let queuedAt: Date
    /// The moments the player asked to have counted. Nil sends every flagged moment.
    var request: LeaderboardTouchReview? = nil
}

@MainActor final class LeaderboardReviewStore: ObservableObject {
    /// A queued session as history knows it: nil while it isn't loaded yet, and
    /// no video once the original has left this phone.
    typealias QueuedSource = (item: HistorySession, video: URL?)

    @Published private(set) var owner: UUID?
    @Published private(set) var attempts: [LeaderboardAttempt] = []
    @Published private(set) var isLoading = false
    @Published private(set) var uploadingSession: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var phase = ""
    @Published var errorMessage: String?
    @Published private(set) var revision = 0
    /// Submissions waiting for their session to sync or for a connection. They
    /// survive relaunches and send themselves; nobody has to come back and retry.
    @Published private(set) var queued: [QueuedLeaderboardSubmission] = []
    /// True after a send failed for want of a connection; the queue retries quietly.
    @Published private(set) var waitingForConnection = false
    /// Finds a queued session in history. Set by the player store.
    var resolveQueued: (UUID) -> QueuedSource? = { _ in nil }
    private let service: (any LeaderboardReviewService)?
    private let root: URL
    private let retryDelay: Duration
    private var retryFailures = 0
    private var generation = UUID()
    private var uploadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    init(service: (any LeaderboardReviewService)?, root: URL, retryDelay: Duration = .seconds(15)) {
        self.service = service; self.root = root; self.retryDelay = retryDelay
    }
    func useAccount(_ owner: UUID?) {
        generation = UUID(); uploadTask?.cancel(); uploadTask = nil
        retryTask?.cancel(); retryTask = nil; retryFailures = 0
        self.owner = owner; attempts = []; uploadingSession = nil; progress = 0; phase = ""
        isLoading = false; errorMessage = nil; waitingForConnection = false
        queued = Self.loadQueue(owner, root: root); revision += 1
    }
    func refresh() async {
        guard let owner, let service else { return }
        let current = generation
        let startedRevision = revision
        isLoading = true; errorMessage = nil
        defer { if generation == current { isLoading = false } }
        do {
            let result = try await service.attempts(owner: owner)
            guard generation == current, revision == startedRevision, !Task.isCancelled else { return }
            guard result.allSatisfy({ $0.userID == owner }) else { throw LeaderboardFailure.unavailable }
            attempts = result; revision += 1
        } catch { if generation == current, !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
    func attempt(for session: UUID) -> LeaderboardAttempt? { attempts.first { $0.sessionID == session } }
    func isQueued(_ session: UUID) -> Bool { queued.contains { $0.sessionID == session } }

    /// Keeps a confirmed submission on this phone and sends it as soon as it can:
    /// once its session has synced to the account and there is a connection.
    func enqueue(item: HistorySession, proposal: RankedStreakProposal, request: LeaderboardTouchReview? = nil) {
        guard let owner, item.ownerID == owner else { errorMessage = LeaderboardFailure.signIn.localizedDescription; return }
        guard item.source == .recording else { errorMessage = LeaderboardFailure.originalRequired.localizedDescription; return }
        guard proposal.isValid(durationMS: item.durationMS) else { errorMessage = LeaderboardFailure.invalidSegment.localizedDescription; return }
        errorMessage = nil
        queued.removeAll { $0.sessionID == item.id }
        queued.append(.init(sessionID: item.id, proposal: proposal, queuedAt: Date(), request: request))
        saveQueue(); revision += 1
        sendQueued()
    }

    func cancelQueued(_ session: UUID) {
        if uploadingSession == session { uploadTask?.cancel() }
        queued.removeAll { $0.sessionID == session }
        saveQueue(); revision += 1
    }

    /// Sends the oldest queued submission that is ready. A lost connection keeps it
    /// queued and retries with a growing pause; a refusal (a limit, a changed
    /// original) drops it and says why. Safe to call whenever conditions change.
    func sendQueued() {
        guard uploadTask == nil, let owner, let service else { return }
        var ready: (entry: QueuedLeaderboardSubmission, item: HistorySession, video: URL)?
        for entry in queued {
            guard let source = resolveQueued(entry.sessionID) else { continue }
            guard let video = source.video else {
                drop(entry, LeaderboardFailure.originalRequired); continue
            }
            if source.item.syncState == .synced { ready = (entry, source.item, video); break }
        }
        guard let ready else { return }
        retryTask?.cancel(); retryTask = nil
        let current = generation
        let entry = ready.entry, item = ready.item, video = ready.video
        uploadingSession = item.id; progress = 0; phase = String(localized: "Checking submission…", bundle: AppLanguage.bundle, locale: AppLanguage.locale); errorMessage = nil
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current { uploadingSession = nil; uploadTask = nil; phase = "" }
            }
            do {
                // Current attempts first: it fails fast offline, before hashing the
                // video, and finds an unfinished upload to resume after a relaunch.
                let latest = try await service.attempts(owner: owner)
                guard generation == current, !Task.isCancelled else { return }
                if latest.allSatisfy({ $0.userID == owner }) { attempts = latest; revision += 1 }
                // For now only short clips of the flagged moments are sent, never the whole recording.
                phase = String(localized: "Preparing clips…", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                let prepared = try await LeaderboardMomentClips.prepare(source: video, review: entry.request ?? item.touchReview,
                    proposal: entry.proposal, durationMS: item.durationMS, folder: clipFolder(owner),
                    session: item.id, limit: LeaderboardRules.maximumVideoBytes)
                try Task.checkCancellation()
                guard generation == current else { return }
                var submitted = item
                submitted.touchReview = prepared.review
                let clips = prepared.file
                let task = Task.detached(priority: .utility) { try LeaderboardVideoFingerprint.read(clips) }
                let fingerprint = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard generation == current else { return }
                var attempt: LeaderboardAttempt
                if let existing = self.attempt(for: item.id) {
                    guard existing.status == .uploading else { throw LeaderboardFailure.conflict }
                    guard existing.videoSHA256 == fingerprint.sha256, existing.videoBytes == fingerprint.bytes else { throw LeaderboardFailure.changedVideo }
                    attempt = existing
                } else {
                    attempt = try await service.begin(item: submitted, proposal: entry.proposal, bytes: fingerprint.bytes, sha256: fingerprint.sha256)
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                attempts.removeAll { $0.id == attempt.id }; attempts.insert(attempt, at: 0)
                revision += 1
                let checkpoint = root.appendingPathComponent("History").appendingPathComponent(owner.uuidString)
                    .appendingPathComponent(attempt.id.uuidString + ".tus")
                if attempt.status == .uploading {
                    // The upload may already have completed while the final response was lost.
                    if let finished = try? await service.finish(id: attempt.id, owner: owner) { attempt = finished }
                    else {
                        try Task.checkCancellation()
                        guard generation == current else { return }
                        phase = String(localized: "Uploading clips…", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                        try await service.upload(file: clips, attempt: attempt, checkpoint: checkpoint, accountRoot: root) { [weak self] value in
                            guard self?.generation == current else { return }; self?.progress = value
                        }
                        try Task.checkCancellation()
                        phase = String(localized: "Sending for review…", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                        attempt = try await service.finish(id: attempt.id, owner: owner)
                    }
                }
                guard generation == current, !Task.isCancelled else { return }
                attempts.removeAll { $0.id == attempt.id }; attempts.insert(attempt, at: 0)
                try? FileManager.default.removeItem(at: checkpoint)
                LeaderboardMomentClips.remove(folder: clipFolder(owner), session: item.id)
                progress = 1; waitingForConnection = false; retryFailures = 0
                queued.removeAll { $0.sessionID == entry.sessionID }
                saveQueue(); revision += 1
                // Hand straight on to the next queued submission, if any.
                Task { @MainActor [weak self] in self?.sendQueued() }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                if Self.isTransient(error) {
                    waitingForConnection = true
                    scheduleRetry()
                } else if case LeaderboardFailure.signIn = error {
                    // Stays queued; signing in again resumes it.
                    errorMessage = LeaderboardFailure.signIn.localizedDescription
                } else {
                    drop(entry, error)
                }
            }
        }
    }

    func pauseUpload() {
        // A paused upload leaves the queue; Resume upload queues it again.
        if let session = uploadingSession { queued.removeAll { $0.sessionID == session }; saveQueue() }
        uploadTask?.cancel()
    }

    private func drop(_ entry: QueuedLeaderboardSubmission, _ error: Error) {
        if let owner { LeaderboardMomentClips.remove(folder: clipFolder(owner), session: entry.sessionID) }
        queued.removeAll { $0.sessionID == entry.sessionID }
        saveQueue(); revision += 1
        errorMessage = (error as? LeaderboardFailure)?.localizedDescription ?? LeaderboardFailure.upload.localizedDescription
    }

    /// Clip files sit beside the account's replays, so deleting the account removes them.
    private func clipFolder(_ owner: UUID) -> URL {
        root.appendingPathComponent("History").appendingPathComponent(owner.uuidString)
    }

    private func scheduleRetry() {
        retryFailures = min(retryFailures + 1, 5)
        let delay = min(retryDelay * (1 << (retryFailures - 1)), .seconds(300))
        let current = generation
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == current else { return }
            self.retryTask = nil
            self.sendQueued()
        }
    }

    /// No connection, a dropped one, or a server that is briefly unavailable.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return true }
        if let failure = error as? LeaderboardFailure { return failure == .upload || failure == .unavailable }
        return false
    }

    private static func queueFile(_ owner: UUID, root: URL) -> URL {
        root.appendingPathComponent("History").appendingPathComponent(owner.uuidString)
            .appendingPathComponent("leaderboard-queue.json")
    }

    private static func loadQueue(_ owner: UUID?, root: URL) -> [QueuedLeaderboardSubmission] {
        guard let owner, let data = try? Data(contentsOf: queueFile(owner, root: root)) else { return [] }
        return (try? JSONDecoder().decode([QueuedLeaderboardSubmission].self, from: data)) ?? []
    }

    private func saveQueue() {
        guard let owner else { return }
        let file = Self.queueFile(owner, root: root), items = queued
        do {
            try AccountDataGuard.write(owner: owner, root: root) {
                if items.isEmpty { try? FileManager.default.removeItem(at: file); return }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtection])
            }
        } catch is CancellationError {
        } catch {
            errorMessage = String(localized: "This submission couldn’t be saved on your phone. Keep the app open until it sends.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
    func withdraw(_ attempt: LeaderboardAttempt) async {
        guard let owner, attempt.userID == owner, let service else { return }
        let current = generation
        if uploadingSession == attempt.sessionID { uploadTask?.cancel(); await uploadTask?.value }
        if isQueued(attempt.sessionID) { queued.removeAll { $0.sessionID == attempt.sessionID }; saveQueue() }
        do {
            try await service.withdraw(id: attempt.id, owner: owner)
            guard generation == current else { return }
            await refresh()
        } catch { if generation == current { errorMessage = error.localizedDescription } }
    }
    func appeal(_ attempt: LeaderboardAttempt, reason: String) async -> Bool {
        guard let owner, attempt.userID == owner, let service else { return false }
        let current = generation
        do {
            try await service.appeal(id: attempt.id, reason: reason, owner: owner)
            guard generation == current else { return false }
            await refresh(); return true
        } catch { if generation == current { errorMessage = error.localizedDescription }; return false }
    }
    func report(_ id: UUID, reason: String) async -> Bool {
        guard let owner, let service else { errorMessage = LeaderboardFailure.signIn.localizedDescription; return false }
        let current = generation
        do { try await service.report(id: id, reason: reason, owner: owner); return generation == current }
        catch { if generation == current { errorMessage = error.localizedDescription }; return false }
    }
    func videoURL(for attempt: LeaderboardAttempt) async throws -> URL {
        guard let owner, attempt.userID == owner, let service else { throw LeaderboardFailure.signIn }
        let current = generation
        let url = try await service.videoURL(attempt: attempt, owner: owner)
        guard current == generation else { throw CancellationError() }
        return url
    }
}
