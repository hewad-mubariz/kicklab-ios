import XCTest
#if canImport(kicklab)
@testable import kicklab
#else
@testable import PreviewCore
#endif

@MainActor final class PreviewMovieCacheTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }
    private func source(_ name: String = "source", bytes: String = "video-source") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }
    private func cache(_ renderer: Renderer, policy: String = "sdr-v1", limit: Int = 1000, files: Int = 4) -> PreviewMovieCache {
        PreviewMovieCache(folder: root.appendingPathComponent("cache"), policy: policy, byteLimit: limit,
            fileLimit: files, render: { try await renderer.render($0) }, validate: {
                try Data(contentsOf: $0).starts(with: Data("preview-".utf8))
            })
    }
    func testEmptyCacheReturnsSourceChoiceWithoutReadingMissingVideo() async throws {
        let c = cache(Renderer())
        let result = try await c.existing(for: root.appendingPathComponent("missing"))
        XCTAssertNil(result)
    }
    func testReimportAndNewCacheInstanceReuseCompletedMovie() async throws {
        let r = Renderer(), src = try source(), copy = try source("reimport")
        let first = try await cache(r).converted(src)
        let second = try await cache(r).existing(for: copy)
        XCTAssertEqual(first, second)
        let count = await r.calls; XCTAssertEqual(count, 1)
    }
    func testChangedBytesAndRenderingPolicyInvalidate() async throws {
        let r = Renderer(), src = try source(), c = cache(r)
        let first = try await c.converted(src)
        try Data("changed".utf8).write(to: src)
        let second = try await c.converted(src)
        let third = try await cache(r, policy: "new-policy").converted(src)
        XCTAssertNotEqual(first, second); XCTAssertNotEqual(second, third)
        let count = await r.calls; XCTAssertEqual(count, 3)
    }
    func testSameSizeCorruptionAndMissingReceiptAreRepaired() async throws {
        let r = Renderer(), src = try source()
        let first = try await cache(r, files: 1).converted(src)
        let bytes = try Data(contentsOf: first).count
        try Data(repeating: 120, count: bytes).write(to: first)
        let second = try await cache(r, files: 1).converted(src)
        XCTAssertEqual(first, second)
        try FileManager.default.removeItem(at: second.deletingPathExtension().appendingPathExtension("json"))
        _ = try await cache(r, files: 1).converted(src)
        let count = await r.calls; XCTAssertEqual(count, 3)
    }
    func testConcurrentConsumersShareWorkAndOneCancellationKeepsOtherAlive() async throws {
        let r = Renderer(delay: .milliseconds(300)), src = try source(), c = cache(r)
        let one = Task { try await c.converted(src) }
        let two = Task { try await c.converted(src) }
        try await Task.sleep(for: .milliseconds(100))
        one.cancel()
        do { _ = try await one.value; XCTFail("Cancelled consumer succeeded") } catch is CancellationError { }
        let output = try await two.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let count = await r.calls; XCTAssertEqual(count, 1)
    }
    func testLastCancellationStopsWorkAndAllowsRetry() async throws {
        let r = Renderer(delay: .milliseconds(300)), src = try source(), c = cache(r)
        let task = Task { try await c.converted(src) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work succeeded") } catch is CancellationError { }
        let missing = try await c.existing(for: src); XCTAssertNil(missing)
        let output = try await c.converted(src)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let count = await r.calls; XCTAssertEqual(count, 2)
        let busy = await c.isBusy; XCTAssertFalse(busy)
    }
    func testInvalidOutputIsRemovedAndFailureCanRetry() async throws {
        let r = Renderer(invalid: true), src = try source(), c = cache(r)
        do { _ = try await c.converted(src); XCTFail("Invalid output accepted") } catch { }
        let missing = try await c.existing(for: src); XCTAssertNil(missing)
        let output = await r.lastOutput
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(output).path))
        await r.setValid()
        _ = try await c.converted(src)
        let count = await r.calls; XCTAssertEqual(count, 2)
    }
    func testActiveMovieIsProtectedAndReleasedMovieCanBeEvicted() async throws {
        let r = Renderer(), c = cache(r, files: 1)
        let a = try source("a", bytes: "a"), b = try source("b", bytes: "b")
        let first = try await c.converted(a)
        let second = try await c.converted(b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertNotEqual(second.deletingLastPathComponent(), first.deletingLastPathComponent())
        // Maintenance releases players before releasing this cache's protection.
        await c.releaseMemory()
        _ = try await c.converted(b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let movies = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }
        XCTAssertEqual(movies.count, 1)
    }
    func testOversizedPreviewIsReusedOnlyWithinSession() async throws {
        let r = Renderer(), c = cache(r, limit: 1), src = try source()
        let first = try await c.converted(src), second = try await c.converted(src)
        XCTAssertEqual(first, second)
        let fresh = try await cache(r, limit: 1).existing(for: src); XCTAssertNil(fresh)
        let count = await r.calls; XCTAssertEqual(count, 1)
    }
    func testReadinessIgnoresBackgroundAndDoesNotTimeoutAfterFrame() {
        var gate = PreviewReadiness(timeout: 10)
        XCTAssertFalse(gate.timedOut(now: 0, active: true))
        XCTAssertFalse(gate.timedOut(now: 4, active: true))
        XCTAssertFalse(gate.timedOut(now: 5, active: false))
        XCTAssertFalse(gate.timedOut(now: 100, active: true))
        XCTAssertFalse(gate.timedOut(now: 105, active: true))
        XCTAssertTrue(gate.timedOut(now: 106, active: true))
        gate.presented()
        XCTAssertFalse(gate.timedOut(now: 1000, active: true))
    }

    func testSuspensionWithoutInactivePollDoesNotConsumeTimeout() {
        var gate = PreviewReadiness(timeout: 10)
        XCTAssertFalse(gate.timedOut(now: 0, active: true))
        XCTAssertFalse(gate.timedOut(now: 4, active: true))
        gate.suspend()
        // No polling at all while iOS suspends the app.
        XCTAssertFalse(gate.timedOut(now: 100, active: true))
        XCTAssertFalse(gate.timedOut(now: 105, active: true))
        XCTAssertTrue(gate.timedOut(now: 106, active: true))
    }
}

private actor Renderer {
    var calls = 0
    var lastOutput: URL?
    let delay: Duration
    var invalid: Bool
    init(delay: Duration = .zero, invalid: Bool = false) { self.delay = delay; self.invalid = invalid }
    func setValid() { invalid = false }
    func render(_ source: URL) async throws -> URL {
        calls += 1
        try await Task.sleep(for: delay)
        let output = source.deletingLastPathComponent().appendingPathComponent("render-\(UUID()).mov")
        try (Data((invalid ? "invalid-" : "preview-").utf8) + Data(contentsOf: source)).write(to: output)
        lastOutput = output
        return output
    }
}
