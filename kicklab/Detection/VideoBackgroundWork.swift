import BackgroundTasks
import Combine
import Foundation
import UIKit

/// A lease belongs to one user-requested job, never to unrelated camera work.
nonisolated final class VideoWorkLease: @unchecked Sendable {
    let cpuOnly: Bool
    let backgroundGPU: Bool
    private let lock = NSLock()
    private var allowed: Bool
    private var cancelled = false
    private var foreground = true
    private var cancelWorker: (@Sendable () -> Void)?
    private let report: @Sendable (Double, String) -> Void

    init(allowed: Bool, cpuOnly: Bool, backgroundGPU: Bool,
         report: @escaping @Sendable (Double, String) -> Void = { _, _ in }) {
        self.allowed = allowed; self.cpuOnly = cpuOnly; self.backgroundGPU = backgroundGPU; self.report = report
    }
    var canContinue: Bool { lock.withLock { allowed && !cancelled } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var isForeground: Bool { lock.withLock { foreground } }
    func setForeground(_ value: Bool) { lock.withLock { foreground = value } }
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
    /// Full image/Vision acceleration remains diagnostic. Normal video jobs
    /// accelerate only the model and retain their existing image-work policy.
    @TaskLocal static var foregroundAccelerationStudy = false
    @TaskLocal static var modelAccelerationStudy = false
    /// Pin image/Vision work to CPU in both arms of an accuracy comparison,
    /// including when iOS declines a background lease. Only the model may vary.
    @TaskLocal static var accuracyComparison = false
    static var isAnalysisStudy: Bool { accuracyComparison || foregroundAccelerationStudy || modelAccelerationStudy }
    static var cpuOnly: Bool { accuracyComparison || (!foregroundAccelerationStudy && lease?.cpuOnly == true) }
    /// A normal video job follows its foreground/background lease. Explicit
    /// CPU comparison runs retain the old backend unless the candidate is selected.
    static var followsModelLifecycle: Bool {
        modelAccelerationStudy || (!accuracyComparison && lease != nil)
    }
    static var modelCPUOnly: Bool {
        if followsModelLifecycle, let lease {
            return !lease.isForeground && !lease.backgroundGPU
        }
        return cpuOnly
    }
    static var canAnalyzeInBackground: Bool {
        lease?.canContinue == true && (!foregroundAccelerationStudy || lease?.backgroundGPU == true)
    }

    /// Detached model/render workers must explicitly inherit their job's lease.
    static func detached<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let current = lease
        let study = foregroundAccelerationStudy
        let modelStudy = modelAccelerationStudy
        let comparison = accuracyComparison
        return Task.detached(priority: .userInitiated) {
            try await $lease.withValue(current) {
                try await $foregroundAccelerationStudy.withValue(study) {
                    try await $modelAccelerationStudy.withValue(modelStudy) {
                        try await $accuracyComparison.withValue(comparison) { try await operation() }
                    }
                }
            }
        }
    }

    static func checkpoint(requiresGPU: Bool = false) async throws {
        while true {
            try Task.checkCancellation()
            if lease?.isCancelled == true { throw CancellationError() }
            let background = await MainActor.run { UIApplication.shared.applicationState == .background }
            if !background || (lease?.canContinue == true && (!(requiresGPU || foregroundAccelerationStudy) || lease?.backgroundGPU == true)) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// iOS owns the background runtime and its progress/cancel Live Activity.
/// If it declines a request, foreground work still runs and resumes on return.
@MainActor
final class VideoBackgroundWork: ObservableObject {
    static let shared = VideoBackgroundWork()
    @Published var interruptedMessage: String?
    private let journal = VideoJobJournal(defaults: .standard)
    private var foregroundJobs = 0
    private var previousIdleTimerDisabled = false
    private init() {
        if journal.consumeInterruptedCount() > 0 {
            interruptedMessage = String(localized: "A video task was interrupted when the app closed. Check Photos for a saved export. If it is missing, reopen your original video and try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
    private final class PendingLease {
        var continuation: CheckedContinuation<VideoWorkLease, Never>?
        init(_ continuation: CheckedContinuation<VideoWorkLease, Never>) { self.continuation = continuation }
        @discardableResult func resolve(_ lease: VideoWorkLease) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil; continuation.resume(returning: lease); return true
        }
    }
    private struct Job {
        let task: BGTask
        let lease: VideoWorkLease
    }
    private var jobs: [String: Job] = [:]

    func run<T: Sendable>(title: String, requiresGPU: Bool = false,
                         operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if VideoWorkExecution.lease != nil { return try await operation() }
        let identifier = "com.juggledude.video." + UUID().uuidString
        journal.begin(identifier, title: title)
        defer { journal.finish(identifier) }
        let lease = await acquire(identifier: identifier, title: title, requiresGPU: requiresGPU)
        let needsForeground = !lease.canContinue
        if needsForeground { beginForegroundWork() }
        defer { if needsForeground { endForegroundWork() } }
        lease.setForeground(UIApplication.shared.applicationState == .active)
        let observers = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main) { _ in lease.setForeground(false) },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { _ in lease.setForeground(true) },
        ]
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
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

    // Count concurrent jobs so one finishing export cannot let the screen sleep
    // while another foreground-only operation is still using the camera model.
    private func beginForegroundWork() {
        if foregroundJobs == 0 {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        foregroundJobs += 1
    }

    private func endForegroundWork() {
        foregroundJobs -= 1
        if foregroundJobs == 0 {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
    }

    private func acquire(identifier: String, title: String, requiresGPU: Bool) async -> VideoWorkLease {
        let fallback = VideoWorkLease(allowed: false, cpuOnly: false, backgroundGPU: false)
        // Older systems run the same job in the foreground. Checkpoints pause
        // it on backgrounding; the journal handles termination and retry.
        guard #available(iOS 26.0, *) else { return fallback }
        let gpu = BGTaskScheduler.supportedResources.contains(.gpu)
        // GPU-only effects wait for foreground on devices that cannot grant GPU access.
        guard !requiresGPU || gpu else { return fallback }
        guard UIApplication.shared.applicationState != .background else { return fallback }
        return await withCheckedContinuation { continuation in
            let pending = PendingLease(continuation)
            // Registration succeeding does not guarantee a timely launch callback.
            // A delayed/denied request must still allow foreground work to start.
            Task {
                try? await Task.sleep(for: .seconds(5))
                if pending.resolve(fallback) {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                }
            }
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated {
                    guard pending.continuation != nil else { task.setTaskCompleted(success: false); return }
                    guard let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false); pending.resolve(fallback); return
                    }
                    let lease = VideoWorkLease(allowed: true, cpuOnly: !gpu, backgroundGPU: gpu) { value, subtitle in
                        Task { @MainActor in
                            guard value.isFinite, let job = self.jobs[identifier], !job.lease.isCancelled,
                                  let task = job.task as? BGContinuedProcessingTask else { return }
                            task.progress.completedUnitCount = min(99, max(task.progress.completedUnitCount, Int64(value * 100)))
                            task.updateTitle(title, subtitle: subtitle)
                        }
                    }
                    task.progress.totalUnitCount = 100
                    task.expirationHandler = { lease.expire() }
                    self.jobs[identifier] = Job(task: task, lease: lease)
                    pending.resolve(lease)
                }
            }
            guard registered else { pending.resolve(fallback); return }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: String(localized: "Preparing your video", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            request.strategy = .fail
            if gpu { request.requiredResources = .gpu }
            do { try BGTaskScheduler.shared.submit(request) }
            catch {
                NSLog("Video background request unavailable: %@", error.localizedDescription)
                pending.resolve(fallback)
            }
        }
    }

    private func finish(_ identifier: String, success: Bool) {
        if let job = jobs.removeValue(forKey: identifier) {
            job.lease.revoke()
            job.task.expirationHandler = nil
            if #available(iOS 26.0, *), success,
               let task = job.task as? BGContinuedProcessingTask {
                task.progress.completedUnitCount = 100
            }
            job.task.setTaskCompleted(success: success)
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
