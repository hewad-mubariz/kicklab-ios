import Foundation

@MainActor
enum VideoStorageMaintenance {
    static private(set) var isActive = false
    static func run<T: Sendable>(_ action: @MainActor () async throws -> T) async throws -> T {
        guard !isActive, !VideoBackgroundWork.shared.isWorking else { throw Failure.busy }
        try VideoStorageAccess.beginMaintenance()
        isActive = true
        defer { isActive = false; VideoStorageAccess.endMaintenance() }
        return try await action()
    }
    static func releaseCachedResults() async throws {
        try await SessionAnalysisStore.shared.releaseCachedResults()
        try await BallSurfaceTimeline.releaseCachedResults()
        try await EffectPreviewCache.shared.releaseCachedResults()
        RFFramePredictionReuse.shared.release()
    }
    enum Failure: LocalizedError {
        case busy
        var errorDescription: String? {
            String(localized: "Finish video processing before managing storage.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
}

/// Atomic admission across actor boundaries: cleanup cannot race a new reader
/// between its idle check and the first asynchronous file/model operation.
nonisolated enum VideoStorageAccess {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var readers = 0
    nonisolated(unsafe) private static var maintaining = false
    static func beginRead() throws -> Token {
        lock.lock(); defer { lock.unlock() }
        guard !maintaining else { throw VideoStorageMaintenance.Failure.busy }
        readers += 1
        return Token()
    }
    static func beginMaintenance() throws {
        lock.lock(); defer { lock.unlock() }
        guard !maintaining, readers == 0 else { throw VideoStorageMaintenance.Failure.busy }
        maintaining = true
    }
    static func endMaintenance() {
        lock.lock(); defer { lock.unlock() }; maintaining = false
    }
    final class Token: @unchecked Sendable {
        private var released = false
        func release() {
            VideoStorageAccess.lock.lock(); defer { VideoStorageAccess.lock.unlock() }
            guard !released else { return }; released = true
            VideoStorageAccess.readers -= 1
        }
        deinit { release() }
    }
}
