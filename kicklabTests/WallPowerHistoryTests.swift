#if DEBUG
import XCTest
@testable import kicklab

final class WallPowerHistoryTests: XCTestCase {
    private func event(_ number: Int) -> WallPowerEvent {
        WallPowerEvent(run: "run-1", event: "sample-\(number)", wallTime: 1_790_000_000 + Double(number),
            uptime: 100 + Double(number), processID: 10, appState: "active", context: "brick-blast-v1",
            power: .init(level: 0.25, charging: .unplugged, lowPowerMode: false), thermalState: 1,
            memoryMiB: 700, cameraResting: false, analysisFPS: 28, inferenceMS: 34,
            brightness: 0.5, idleTimerDisabled: true)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func read(_ file: URL) throws -> [WallPowerEvent] {
        try Data(contentsOf: file).split(separator: 0x0A).map {
            try JSONDecoder().decode(WallPowerEvent.self, from: Data($0))
        }
    }

    func testUnavailableBatteryNeverLooksLikeEmptyBattery() {
        for level: Float in [-1, .nan, .infinity, 1.1] {
            XCTAssertNil(WallPowerReading(level: level, charging: .unknown, lowPowerMode: false).batteryPercent)
        }
        XCTAssertEqual(WallPowerReading(level: 0, charging: .unplugged, lowPowerMode: false).batteryPercent, 0)
        XCTAssertEqual(WallPowerReading(level: 0.31, charging: .charging, lowPowerMode: true).label,
            "Battery 31% · charging · Low Power")
    }

    func testOldResourceHistoryWithoutBatteryStillDecodes() throws {
        let legacy = Data(#"{"uptime":123,"memoryMiB":700,"thermalState":1,"analysisFPS":23,"captureFPS":60,"inferenceMS":40,"cameraResting":false}"#.utf8)
        let sample = try JSONDecoder().decode(WallRuntimeSample.self, from: legacy)
        XCTAssertNil(sample.power)
        XCTAssertNil(sample.wallTime)
        XCTAssertEqual(sample.memoryMiB, 700)
    }

    func testLegacyPowerEventAndNewContextRoundTrip() throws {
        var sample = event(0)
        let old = try JSONDecoder().decode(WallPowerEvent.self, from: JSONEncoder().encode(sample))
        XCTAssertNil(old.environment)
        XCTAssertNil(old.gameplay)
        XCTAssertNil(old.captureFPS)
        sample.environment = WallPowerEnvironment(hardware: "iPhone12,5", osVersion: "test",
            bundleIdentifier: "test", appVersion: "1", appBuild: "13", buildFingerprint: "snapshot",
            physicalMemoryMiB: 4096)
        sample.gameplay = WallPowerGameplay(phase: "playing", recording: false, macPreview: false)
        sample.captureFPS = 59.8
        sample.cpuSeconds = 123.4
        let decoded = try JSONDecoder().decode(WallPowerEvent.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(decoded.environment?.hardware, "iPhone12,5")
        XCTAssertEqual(decoded.environment?.schemaVersion, 2)
        XCTAssertEqual(decoded.environment?.buildFingerprint, "snapshot")
        XCTAssertEqual(decoded.gameplay, sample.gameplay)
        XCTAssertEqual(decoded.captureFPS, sample.captureFPS)
        XCTAssertEqual(decoded.cpuSeconds, sample.cpuSeconds)
    }

    func testReopeningHistoryKeepsPriorSamplesAndRepairsInterruptedLastLine() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("power-0.jsonl")
        try WallPowerHistory(folder: folder).append(event(0))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"run":"interrupted"#.utf8))
        try handle.close()
        var next = event(1)
        next.run = "run-2"
        try WallPowerHistory(folder: folder).append(next)
        let rows = try read(file)
        XCTAssertEqual(rows.map(\.event), ["sample-0", "sample-1"])
        XCTAssertEqual(rows.map(\.run), ["run-1", "run-2"])
    }

    func testRotationRetainsNewestHistoryWithinStorageBound() throws {
        let folder = try temporaryFolder()
        let limit = (try JSONEncoder().encode(event(0)).count + 1) * 2 + 8
        let writer = WallPowerHistory(folder: folder, maximumFileBytes: limit, retainedFiles: 3)
        for number in 0..<10 { try writer.append(event(number)) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        XCTAssertEqual(files.count, 3)
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, limit) }
        XCTAssertEqual(try files.flatMap { try read($0) }.map(\.event), (4..<10).map { "sample-\($0)" })
        try WallPowerHistory(folder: folder, maximumFileBytes: limit, retainedFiles: 3).append(event(10))
        XCTAssertEqual(try read(folder.appendingPathComponent("power-0.jsonl")).last?.event, "sample-10")
    }

    func testOversizedEntryDoesNotDestroyPriorHistory() throws {
        let folder = try temporaryFolder()
        let writer = WallPowerHistory(folder: folder, maximumFileBytes: 1024, retainedFiles: 2)
        try writer.append(event(0))
        var huge = event(1)
        huge.event = String(repeating: "x", count: 2000)
        XCTAssertThrowsError(try writer.append(huge))
        XCTAssertEqual(try read(folder.appendingPathComponent("power-0.jsonl")).map(\.event), ["sample-0"])
    }
}
#endif
