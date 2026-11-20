#if DEBUG
import Foundation

nonisolated struct WallPowerReading: Codable, Equatable, Sendable {
    enum Charging: String, Codable, Sendable { case unknown, unplugged, charging, full }
    var batteryPercent: Double?
    var charging: Charging
    var lowPowerMode: Bool

    init(level: Float, charging: Charging, lowPowerMode: Bool) {
        batteryPercent = level.isFinite && (0...1).contains(level) ? (Double(level) * 100).rounded() : nil
        self.charging = charging
        self.lowPowerMode = lowPowerMode
    }

    var label: String {
        let percent = batteryPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let state: String = switch charging {
        case .unknown: "checking"
        case .unplugged: "on battery"
        case .charging: "charging"
        case .full: "full"
        }
        return "Battery \(percent) · \(state)" + (lowPowerMode ? " · Low Power" : "")
    }
}

nonisolated struct WallPowerEvent: Codable, Sendable {
    var run: String
    var event: String
    var wallTime: Double
    var uptime: Double
    var processID: Int32
    var appState: String
    var context: String
    var power: WallPowerReading
    var thermalState: Int
    var memoryMiB: Double?
    var cameraResting: Bool?
    var analysisFPS: Double?
    var inferenceMS: Double?
    var brightness: Double
    var idleTimerDisabled: Bool
    // Optional additions keep existing device histories readable.
    var environment: WallPowerEnvironment?
    var gameplay: WallPowerGameplay?
    var captureFPS: Double?
    var cpuSeconds: Double?
    var displayCount: Int?
    /// Also true for screen recording; this alone does not prove AirPlay use.
    var screenCaptured: Bool?
}

nonisolated struct WallPowerEnvironment: Codable, Sendable {
    var schemaVersion = 2
    var hardware: String
    var osVersion: String
    var bundleIdentifier: String
    var appVersion: String
    var appBuild: String
    var buildFingerprint: String?
    var physicalMemoryMiB: Double
}

nonisolated struct WallPowerGameplay: Codable, Equatable, Sendable {
    var phase: String
    var recording: Bool
    var macPreview: Bool
}

/// Queue-owned, bounded JSONL history. Each append closes its handle, so an app
/// relaunch keeps the history. Sudden power loss may still lose the final write;
/// a partial last line is repaired before appending after the next launch.
nonisolated final class WallPowerHistory {
    private let folder: URL
    private let maximumFileBytes: Int
    private let retainedFiles: Int
    private var prepared = false
    private var currentBytes = 0

    init(folder: URL, maximumFileBytes: Int = 256 * 1024, retainedFiles: Int = 8) {
        precondition(maximumFileBytes > 0 && retainedFiles > 0)
        self.folder = folder
        self.maximumFileBytes = maximumFileBytes
        self.retainedFiles = retainedFiles
    }

    func append(_ event: WallPowerEvent) throws {
        let data = try JSONEncoder().encode(event) + Data([0x0A])
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        if !prepared { try prepare() }
        if currentBytes + data.count > maximumFileBytes { try rotate() }
        let url = file(0)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        currentBytes += data.count
    }

    private func file(_ index: Int) -> URL { folder.appendingPathComponent("power-\(index).jsonl") }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = file(0)
        if FileManager.default.fileExists(atPath: url.path) {
            var data = try Data(contentsOf: url)
            if !data.isEmpty && data.last != 0x0A {
                data = data.lastIndex(of: 0x0A).map { Data(data[...$0]) } ?? Data()
                try data.write(to: url, options: .atomic)
            }
            currentBytes = data.count
        }
        prepared = true
    }

    private func rotate() throws {
        let manager = FileManager.default
        let oldest = file(retainedFiles - 1)
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        if retainedFiles > 1 {
            for index in stride(from: retainedFiles - 2, through: 0, by: -1) {
                let source = file(index)
                if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: file(index + 1)) }
            }
        }
        currentBytes = 0
    }
}
#endif
