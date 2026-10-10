import Foundation
import UIKit

/// Reduce sustained offline work only when iOS reports thermal pressure.
/// Sleep between frames, never change source timestamps, skip frames, alter
/// inference precision, or slow the live camera's counting cadence.
nonisolated struct VideoAnalysisPacer {
    private(set) var waitingSeconds = 0.0
    private(set) var peakThermalState = 0
    private(set) var pacingSleeps = 0
    private var dutyCycle = 1.0
    private var waitingDebt = 0.0
    private let enabled: Bool
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let isBackground: @Sendable () async -> Bool
    private let canContinueInBackground: @Sendable () -> Bool

    init(enabled: Bool = true,
         thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         isBackground: @escaping @Sendable () async -> Bool = {
             await MainActor.run { UIApplication.shared.applicationState == .background }
         },
         canContinueInBackground: @escaping @Sendable () -> Bool = { VideoWorkExecution.lease?.canContinue == true }) {
        self.enabled = enabled
        self.thermalState = thermalState
        self.isBackground = isBackground
        self.canContinueInBackground = canContinueInBackground
    }

    static func dutyCycle(for state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal: return 1
        case .fair: return 0.75
        case .serious: return 0.5
        case .critical: return 0
        @unknown default: return 0.5
        }
    }

    static func delay(workSeconds: Double, dutyCycle: Double) -> Double {
        guard workSeconds.isFinite, workSeconds > 0, dutyCycle > 0, dutyCycle < 1 else { return 0 }
        return min(0.25, workSeconds * (1 / dutyCycle - 1))
    }

    /// Called before decoding, so a background/critical pause cannot pile up
    /// decoded frames or enqueue further model predictions.
    mutating func beginFrame(onCooling: @Sendable (Bool) async -> Void) async throws -> Double {
        try Task.checkCancellation()
        if VideoWorkExecution.lease?.isCancelled == true { throw CancellationError() }
        guard enabled else { return ProcessInfo.processInfo.systemUptime }
        var cooling = false
        var paused = false
        while true {
            if VideoWorkExecution.lease?.isCancelled == true { throw CancellationError() }
            let thermal = thermalState()
            peakThermalState = max(peakThermalState, thermal.rawValue)
            dutyCycle = Self.dutyCycle(for: thermal)
            let background = await isBackground() && !canContinueInBackground()
            if thermal == .critical, !cooling { cooling = true; await onCooling(true) }
            if dutyCycle > 0, !background { break }
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(1))
            waitingSeconds += ProcessInfo.processInfo.systemUptime - start
            paused = true
        }
        if paused { waitingDebt = 0 }
        if cooling { await onCooling(false) }
        return ProcessInfo.processInfo.systemUptime
    }

    mutating func finishFrame(started: Double) async throws {
        guard enabled else { return }
        guard dutyCycle < 1 else { waitingDebt = 0; return }
        waitingDebt += Self.delay(workSeconds: ProcessInfo.processInfo.systemUptime - started, dutyCycle: dutyCycle)
        // Amortize short sleeps over a few frames. This keeps the same average
        // duty budget without waking the task/accelerators for every tiny gap.
        // Account for actual suspension, including the scheduler's overshoot.
        guard waitingDebt >= 0.04 else { return }
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(min(0.25, waitingDebt)))
        let waited = ProcessInfo.processInfo.systemUptime - start
        waitingSeconds += waited
        waitingDebt = max(-0.25, waitingDebt - waited)
        pacingSleeps += 1
    }
}
