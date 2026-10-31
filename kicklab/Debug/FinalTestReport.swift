#if DEBUG
import Foundation

/// Test evidence is separate from product history and never grants a ranked score.
nonisolated struct FinalTestReport: Codable, Sendable, Identifiable {
    static let durations = [30, 60, 120, 180, 300, 600, 900]
    static let stageNames = ["recording", "video", "analysis", "replay", "export"]
    static let reviewNames = ["Touch accuracy", "Replay counter / timer", "Export counter / timer", "Performance"]
    struct Stage: Codable, Sendable {
        var status = "pending"
        var started: Date?
        var finished: Date?
        var detail = ""
        var metrics: [String: Double] = [:]
    }
    let id: UUID
    let targetSeconds: Int
    let started: Date
    var updated: Date
    let build: String
    let device: String
    let os: String
    let model: String
    let pipeline: String
    var stages = Dictionary(uniqueKeysWithValues: stageNames.map { ($0, Stage()) })
    var reviews = Dictionary(uniqueKeysWithValues: reviewNames.map { ($0, "pending") })
    var notes = ""
    var expectedTouches: Int?
    var liveTouches: Int?
    var analyzedTouches: Int?
    var analysisBuild: String?
    var analysisPipeline: String?
    var originalVideoName: String?
    var retainedVideoName: String?
    var analysisDirectory: String?
    var retainedExportName: String?
    var sourceSHA256: String?
    var peakMemoryMiB = 0.0
    var worstThermal = "nominal"
    var storageError: String?

    var verdict: String {
        if storageError != nil || stages.values.contains(where: { ["failed", "interrupted", "short"].contains($0.status) })
            || reviews.values.contains("issues") { return "needs attention" }
        let ready = Self.stageNames.allSatisfy { name in
            stages[name]?.status == (name == "replay" ? "opened" : "completed")
        }
        return ready && Self.reviewNames.allSatisfy { reviews[$0] == "passed" }
            ? "reviewed pass" : "pending validation"
    }

    mutating func recoverInterruptedStages() {
        for name in Self.stageNames where stages[name]?.status == "running" {
            stages[name]?.status = "interrupted"
            stages[name]?.finished = Date()
            stages[name]?.detail = "App ended before this stage completed. Previous evidence retained."
        }
    }
}

/// Small append-only journals keep all contact decisions even after the bounded
/// numeric counter trace fills. No disk encoding/writes run on capture or inference.
nonisolated final class FinalTestFiles: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.juggledude.final-test-evidence", qos: .utility)
    private let failure: @Sendable (String) -> Void

    init(directory: URL, failure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.directory = directory
        self.failure = failure
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func ensureJournal(_ name: String) {
        queue.async {
            let url = self.directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            do { try Data().write(to: url) } catch { self.failure(error.localizedDescription) }
        }
    }

    func save<T: Encodable & Sendable>(_ value: T, as name: String) {
        queue.async {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(value).write(to: self.directory.appendingPathComponent(name), options: .atomic)
            } catch { self.failure(error.localizedDescription) }
        }
    }

    func append<T: Encodable & Sendable>(_ value: T, to name: String) {
        queue.async {
            do {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(value); data.append(0x0A)
                let url = self.directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                }
            } catch { self.failure(error.localizedDescription) }
        }
    }

    func saveBinary<T: Encodable & Sendable>(_ value: T, as name: String) {
        queue.async {
            do {
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(value).write(to: self.directory.appendingPathComponent(name), options: .atomic)
            } catch { self.failure(error.localizedDescription) }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
#endif
