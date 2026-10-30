import Foundation

/// Optional engineering timings. No images are retained and no stage changes
/// its work or frame selection when measurement is enabled.
nonisolated struct BallPreparationTiming: Codable, Sendable {
    enum Stage: String, Codable, Sendable {
        case setup, scheduling, decoding, guide, outline, patch, pyramid, exposure, rotation, lighting
    }
    struct Measurement: Codable, Sendable {
        var seconds = 0.0
        var calls = 0
    }
    private(set) var stages: [String: Measurement] = [:]
    var decodedFrames = 0
    var fittedFrames = 0
    var rotationPairs = 0
    var acceptedPairs = 0
    var totalSeconds = 0.0
    let enabled: Bool

    static var enabledForBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    mutating func measure<T>(_ stage: Stage, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = ProcessInfo.processInfo.systemUptime
        defer { record(stage, since: start) }
        return try work()
    }

    mutating func record(_ stage: Stage, since start: Double) {
        guard enabled else { return }
        var value = stages[stage.rawValue, default: Measurement()]
        value.seconds += max(0, ProcessInfo.processInfo.systemUptime - start)
        value.calls += 1
        stages[stage.rawValue] = value
    }

    /// Separate this request's latency from a cached timeline's historical cost.
    static func writeRequest(origin: String, key: String, since start: Double,
                             computation: Self?) {
        #if DEBUG && canImport(UIKit)
        struct Report: Encodable {
            let origin, key: String
            let finishedAt: Date
            let requestSeconds: Double
            let computation: BallPreparationTiming?
        }
        let report = Report(origin: origin, key: key, finishedAt: Date(),
            requestSeconds: ProcessInfo.processInfo.systemUptime - start, computation: computation)
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("ball-preparation-timing.json"), options: .atomic)
        }
        #endif
    }
}
