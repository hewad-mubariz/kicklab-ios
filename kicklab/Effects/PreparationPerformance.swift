import Foundation

/// Opt-in Release measurements. Disabled for normal launches; writes only stage
/// durations/counters, never pixels or model tensors. Does not change work policy.
nonisolated final class PreparationPerformance: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--preparation-profile")
    private static let shared = PreparationPerformance()
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private let file = URL.documentsDirectory.appending(path: "exact-clip-check/preparation-stages.json")

    static func reset() {
        guard enabled else { return }
        shared.lock.lock(); defer { shared.lock.unlock() }
        shared.events.removeAll()
        try? Data("[]".utf8).write(to: shared.file, options: .atomic)
    }

    static func record(_ stage: String, _ metrics: [String: Double]) {
        guard enabled else { return }
        shared.lock.lock(); defer { shared.lock.unlock() }
        shared.events.append(["stage": stage, "uptime": ProcessInfo.processInfo.systemUptime, "metrics": metrics])
        if let data = try? JSONSerialization.data(withJSONObject: shared.events, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: shared.file, options: .atomic)
        }
    }
}
