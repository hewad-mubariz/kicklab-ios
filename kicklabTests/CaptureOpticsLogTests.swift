import XCTest
@testable import kicklab

final class CaptureOpticsLogTests: XCTestCase {
    func testOrdinaryRecordingsKeepSeparateOrderedOpticsLogsAndFinalCounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CaptureOpticsLog(source: URL(fileURLWithPath: "/tmp/first.mov"), directory: directory)
        let second = CaptureOpticsLog(source: URL(fileURLWithPath: "/tmp/second.mov"), directory: directory)
        var sample = CaptureCadenceSnapshot()
        sample.optics = .init(recordingSeconds: 0.1, exposureSeconds: 1.0 / 120,
                              iso: 320, exposureTargetOffset: 0)
        first.append(sample)
        sample.duration = 1.1
        sample.optics = .init(recordingSeconds: 1.1, exposureSeconds: 1.0 / 60,
                              iso: 160, exposureTargetOffset: -0.2)
        first.append(sample)
        sample.writtenFrames = 90
        let final = sample
        await withCheckedContinuation { continuation in
            first.finish(final) { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            second.finish(CaptureCadenceSnapshot()) { continuation.resume() }
        }
        func entries(_ log: CaptureOpticsLog) throws -> [CaptureOpticsLog.Entry] {
            try Data(contentsOf: log.url).split(separator: 10).map {
                try JSONDecoder().decode(CaptureOpticsLog.Entry.self, from: Data($0))
            }
        }
        let a = try entries(first), b = try entries(second)
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a.map(\.source), Array(repeating: "first.mov", count: 3))
        XCTAssertEqual(a.map(\.final), [false, false, true])
        XCTAssertEqual(a[0].capture.optics?.exposureSeconds, 1.0 / 120)
        XCTAssertEqual(a[1].capture.optics?.recordingSeconds, 1.1)
        XCTAssertEqual(a[2].capture.writtenFrames, 90)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].source, "second.mov")
        XCTAssertNil(b[0].capture.optics)
    }
}
