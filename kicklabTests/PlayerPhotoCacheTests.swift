import XCTest
import UIKit
@testable import kicklab

@MainActor
final class PlayerPhotoCacheTests: XCTestCase {
    private func jpeg(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }.jpegData(compressionQuality: 0.9)!
    }
    private func reference(_ id: UUID = UUID()) -> PlayerPhotoReference {
        .init(playerID: id, path: id.uuidString + "/avatar.jpg")
    }

    func testRowsAndDetailsShareOneDownloadAndCachePixels() async {
        let cache = PlayerPhotoCache(), ref = reference(), data = jpeg(.red)
        var calls = 0
        var finish: CheckedContinuation<Data, Never>?
        let first = Task { await cache.load(ref) { calls += 1; return await withCheckedContinuation { finish = $0 } } }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        let second = Task { await cache.load(ref) { calls += 1; return self.jpeg(.blue) } }
        await Task.yield()
        finish?.resume(returning: data)
        let a = await first.value, b = await second.value
        XCTAssertEqual(a, data); XCTAssertEqual(b, data)
        let warm = await cache.load(ref) { calls += 1; return self.jpeg(.blue) }
        XCTAssertEqual(warm, data); XCTAssertEqual(calls, 1)
        XCTAssertNotNil(cache.image(for: ref)); XCTAssertFalse(cache.isLoading(ref))
    }

    func testDifferentPlayersNeverSharePixelsEvenWithSameRankOrPath() async {
        let cache = PlayerPhotoCache(), a = reference(), b = PlayerPhotoReference(playerID: UUID(), path: "avatar.jpg")
        let red = jpeg(.red), blue = jpeg(.blue)
        let first = await cache.load(a) { red }, second = await cache.load(b) { blue }
        XCTAssertEqual(first, red); XCTAssertEqual(second, blue)
        let one = LeaderboardEntry(rank: 1, name: "Alex", touches: 50, userID: a.playerID)
        let two = LeaderboardEntry(rank: 1, name: "Alex", touches: 70, userID: b.playerID)
        let moved = LeaderboardEntry(rank: 3, name: "New name", touches: 50, userID: a.playerID)
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(one.id, moved.id)
    }

    func testExpiredPhotoRenewsAndFailuresCanRetry() async {
        var date = Date()
        let cache = PlayerPhotoCache(lifetime: 300, now: { date }), ref = reference()
        var calls = 0
        let red = jpeg(.red), blue = jpeg(.blue)
        _ = await cache.load(ref) { calls += 1; return red }
        date = date.addingTimeInterval(301)
        let fallback = await cache.load(ref) { calls += 1; throw URLError(.timedOut) }
        XCTAssertEqual(fallback, red)
        let renewed = await cache.load(ref) { calls += 1; return blue }
        XCTAssertEqual(renewed, blue); XCTAssertEqual(calls, 3)
    }

    func testAccountChangeRejectsLatePhotoAndNewUploadWinsOverOldDownload() async throws {
        let cache = PlayerPhotoCache(), ref = reference(), old = jpeg(.red), new = jpeg(.blue)
        var finish: CheckedContinuation<Data, Never>?
        let request = Task { await cache.load(ref) { await withCheckedContinuation { finish = $0 } } }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        cache.reset()
        finish?.resume(returning: old)
        _ = await request.value
        XCTAssertNil(cache.image(for: ref))
        finish = nil
        let stale = Task { await cache.load(ref) { await withCheckedContinuation { finish = $0 } } }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        try cache.store(new, for: ref)
        finish?.resume(returning: old)
        _ = await stale.value
        let retained = await cache.load(ref) { XCTFail("Uploaded photo should be cached"); return old }
        XCTAssertEqual(retained, new)
        cache.remove(ref)
        XCTAssertNil(cache.image(for: ref))
    }

    func testPhotoMemoryBudgetEvictsTheOlderPlayerAndReloadsOnDemand() async throws {
        let data = jpeg(.red), image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        let cost = data.count + image.bytesPerRow * image.height
        var date = Date()
        let cache = PlayerPhotoCache(maximumBytes: cost + 1, now: { date })
        let a = reference(), b = reference()
        let identity = cache.identity(for: a)
        _ = await cache.load(a) { data }
        date = date.addingTimeInterval(1)
        _ = await cache.load(b) { data }
        XCTAssertNil(cache.image(for: a)); XCTAssertNotNil(cache.image(for: b))
        XCTAssertEqual(cache.identity(for: a), identity, "Eviction must not reset a visible avatar")
        date = date.addingTimeInterval(1)
        _ = await cache.load(a) { data }
        XCTAssertNotNil(cache.image(for: a)); XCTAssertNil(cache.image(for: b))
        cache.remove(a)
        XCTAssertNotEqual(cache.identity(for: a), identity, "Explicit removal must reset a visible avatar")
    }

    func testInvalidPhotoIsNotCachedAndCanBeRetried() async {
        let cache = PlayerPhotoCache(), ref = reference()
        let invalid = await cache.load(ref) { Data("invalid image".utf8) }
        XCTAssertNil(invalid); XCTAssertNil(cache.image(for: ref))
        _ = await cache.load(ref) { self.jpeg(.red) }
        XCTAssertNotNil(cache.image(for: ref))
    }
}
