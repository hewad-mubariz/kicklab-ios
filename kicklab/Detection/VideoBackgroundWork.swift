import BackgroundTasks
import Foundation
import UIKit

/// A lease belongs to one user-requested job, never to unrelated camera work.
nonisolated final class VideoWorkLease: @unchecked Sendable {
    let cpuOnly: Bool
    let backgroundGPU: Bool
    private let lock = NSLock()
    private var allowed: Bool
    private var cancelled = false
    private var cancelWorker: (@Sendable () -> Void)?
    private let report: @Sendable (Double, String) -> Void

    init(allowed: Bool, cpuOnly: Bool, backgroundGPU: Bool,
         report: @escaping @Sendable (Double, String) -> Void = { _, _ in }) {
        self.allowed = allowed; self.cpuOnly = cpuOnly; self.backgroundGPU = backgroundGPU; self.report = report
    }
    var canContinue: Bool { lock.withLock { allowed && !cancelled } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func expire() {
        let action = lock.withLock { cancelled = true; allowed = false; return cancelWorker }
        action?()
    }
    func onExpiration(_ action: @escaping @Sendable () -> Void) {
        let expired = lock.withLock { cancelWorker = action; return cancelled }
        if expired { action() }
    }
    func revoke() { lock.withLock { allowed = false } }
    func releaseWorker() { lock.withLock { cancelWorker = nil } }
    func progress(_ value: Double, subtitle: String) { report(value, subtitle) }
}

nonisolated enum VideoWorkExecution {
    @TaskLocal static var lease: VideoWorkLease?
    static var cpuOnly: Bool { lease?.cpuOnly == true }

    /// Detached model/render workers must explicitly inherit their job's lease.
    static func detached<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let current = lease
        return Task.detached(priority: .userInitiated) {
            try await $lease.withValue(current) { try await operation() }
        }
    }

    static func checkpoint(requiresGPU: Bool = false) async throws {
        while true {
            try Task.checkCancellation()
            if lease?.isCancelled == true { throw CancellationError() }
            let background = await MainActor.run { UIApplication.shared.applicationState == .background }
            if !background || (lease?.canContinue == true && (!requiresGPU || lease?.backgroundGPU == true)) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// iOS owns the background runtime and its progress/cancel Live Activity.
/// If it declines a request, foreground work still runs and resumes on return.
@MainActor
final class VideoBackgroundWork {
    static let shared = VideoBackgroundWork()
    private struct Job {
        let task: BGContinuedProcessingTask
        let lease: VideoWorkLease
    }
    private var jobs: [String: Job] = [:]

    func run<T: Sendable>(title: String, requiresGPU: Bool = false,
                         operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if VideoWorkExecution.lease != nil { return try await operation() }
        let identifier = "com.juggledude.video." + UUID().uuidString
        let lease = await acquire(identifier: identifier, title: title, requiresGPU: requiresGPU)
        let worker = Task {
            try await VideoWorkExecution.$lease.withValue(lease) {
                try await VideoWorkExecution.checkpoint(requiresGPU: requiresGPU)
                return try await operation()
            }
        }
        lease.onExpiration { worker.cancel() }
        defer { lease.releaseWorker() }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                lease.expire(); worker.cancel()
            }
            finish(identifier, success: !lease.isCancelled)
            try Task.checkCancellation()
            if lease.isCancelled { throw CancellationError() }
            return result
        } catch {
            lease.expire(); worker.cancel()
            finish(identifier, success: false)
            throw error
        }
    }

    private func acquire(identifier: String, title: String, requiresGPU: Bool) async -> VideoWorkLease {
        let gpu = BGTaskScheduler.supportedResources.contains(.gpu)
        let fallback = VideoWorkLease(allowed: false, cpuOnly: false, backgroundGPU: false)
        // GPU-only effects wait for foreground on devices that cannot grant GPU access.
        guard !requiresGPU || gpu else { return fallback }
        guard UIApplication.shared.applicationState != .background else { return fallback }
        return await withCheckedContinuation { continuation in
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated {
                    guard let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false); continuation.resume(returning: fallback); return
                    }
                    let lease = VideoWorkLease(allowed: true, cpuOnly: !gpu, backgroundGPU: gpu) { value, subtitle in
                        Task { @MainActor in
                            guard value.isFinite, let job = self.jobs[identifier], !job.lease.isCancelled else { return }
                            job.task.progress.completedUnitCount = min(99, max(job.task.progress.completedUnitCount, Int64(value * 100)))
                            job.task.updateTitle(title, subtitle: subtitle)
                        }
                    }
                    task.progress.totalUnitCount = 100
                    task.expirationHandler = { lease.expire() }
                    self.jobs[identifier] = Job(task: task, lease: lease)
                    continuation.resume(returning: lease)
                }
            }
            guard registered else { continuation.resume(returning: fallback); return }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Preparing your video")
            request.strategy = .fail
            if gpu { request.requiredResources = .gpu }
            do { try BGTaskScheduler.shared.submit(request) }
            catch {
                NSLog("Video background request unavailable: %@", error.localizedDescription)
                continuation.resume(returning: fallback)
            }
        }
    }

    private func finish(_ identifier: String, success: Bool) {
        if let job = jobs.removeValue(forKey: identifier) {
            job.lease.revoke()
            job.task.expirationHandler = nil
            if success { job.task.progress.completedUnitCount = 100 }
            job.task.setTaskCompleted(success: success)
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
