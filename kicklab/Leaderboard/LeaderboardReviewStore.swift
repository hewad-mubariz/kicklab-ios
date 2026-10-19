import Combine
import Foundation

@MainActor final class LeaderboardReviewStore: ObservableObject {
    @Published private(set) var owner: UUID?
    @Published private(set) var attempts: [LeaderboardAttempt] = []
    @Published private(set) var isLoading = false
    @Published private(set) var uploadingSession: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var phase = ""
    @Published var errorMessage: String?
    @Published private(set) var revision = 0
    private let service: (any LeaderboardReviewService)?
    private let root: URL
    private var generation = UUID()
    private var uploadTask: Task<Void, Never>?
    init(service: (any LeaderboardReviewService)?, root: URL) { self.service = service; self.root = root }
    func useAccount(_ owner: UUID?) {
        generation = UUID(); uploadTask?.cancel(); uploadTask = nil
        self.owner = owner; attempts = []; uploadingSession = nil; progress = 0; phase = ""
        isLoading = false; errorMessage = nil; revision += 1
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
    func submit(item: HistorySession, proposal: RankedStreakProposal, video: URL) {
        guard uploadTask == nil else { return }
        guard let owner, item.ownerID == owner else { errorMessage = LeaderboardFailure.signIn.localizedDescription; return }
        guard item.source == .recording, item.syncState == .synced else { errorMessage = "Wait for this recording to sync to your account, then try again."; return }
        guard proposal.isValid(durationMS: item.durationMS) else { errorMessage = LeaderboardFailure.invalidSegment.localizedDescription; return }
        guard let service else { errorMessage = LeaderboardFailure.unavailable.localizedDescription; return }
        let current = generation
        uploadingSession = item.id; progress = 0; phase = "Checking original…"; errorMessage = nil
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current { uploadingSession = nil; uploadTask = nil; phase = "" }
            }
            do {
                let task = Task.detached(priority: .utility) { try LeaderboardVideoFingerprint.read(video) }
                let fingerprint = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard generation == current else { return }
                var attempt: LeaderboardAttempt
                if let existing = self.attempt(for: item.id) {
                    guard existing.status == .uploading else { throw LeaderboardFailure.conflict }
                    guard existing.videoSHA256 == fingerprint.sha256, existing.videoBytes == fingerprint.bytes else { throw LeaderboardFailure.changedVideo }
                    attempt = existing
                } else {
                    attempt = try await service.begin(item: item, proposal: proposal, bytes: fingerprint.bytes, sha256: fingerprint.sha256)
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
                        phase = "Uploading original…"
                        try await service.upload(file: video, attempt: attempt, checkpoint: checkpoint, accountRoot: root) { [weak self] value in
                            guard self?.generation == current else { return }; self?.progress = value
                        }
                        try Task.checkCancellation()
                        phase = "Sending for review…"
                        attempt = try await service.finish(id: attempt.id, owner: owner)
                    }
                }
                guard generation == current, !Task.isCancelled else { return }
                attempts.removeAll { $0.id == attempt.id }; attempts.insert(attempt, at: 0)
                try? FileManager.default.removeItem(at: checkpoint)
                progress = 1; revision += 1
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                errorMessage = (error as? LeaderboardFailure)?.localizedDescription ?? LeaderboardFailure.upload.localizedDescription
            }
        }
    }
    func pauseUpload() { uploadTask?.cancel() }
    func withdraw(_ attempt: LeaderboardAttempt) async {
        guard let owner, attempt.userID == owner, let service else { return }
        let current = generation
        if uploadingSession == attempt.sessionID { uploadTask?.cancel(); await uploadTask?.value }
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
