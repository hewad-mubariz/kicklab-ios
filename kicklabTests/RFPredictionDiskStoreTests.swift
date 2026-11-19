import CoreGraphics
import Foundation
import SQLite3
import XCTest
@testable import kicklab

final class RFPredictionDiskStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rf-persistence-test-"+UUID().uuidString)
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
    private func key(_ index: Int = 0, model: String = "model-sha|rf288", cpu: Bool = false, threshold: Double = 0.4, width: Int = 720) -> RFFramePredictionCache.Key {
        .init(input: .init(digest: RFPredictionDiskStore.digest(Data(String(index).utf8)), edge: 288, width: width, height: 1280), model: model, cpuOnly: cpu, threshold: threshold)
    }
    private func disk(source: String = "clip-content-sha", runtime: String = "phone-os", limit: Int = 2*1024*1024) throws -> RFPredictionDiskStore {
        try RFPredictionDiskStore(root: root, source: source, runtime: runtime, byteLimit: limit)
    }
    private func value(_ score: Double = 0.8, noise: Bool = false) -> FrameDetections {
        let ball = Detection(score: score, x: 0.37, y: 0.61, width: 0.083, height: 0.051)
        let person = Detection(score: 0.9, x: 0.3, y: 0.5, width: 0.2, height: 0.7)
        let alpha: [UInt8] = (0..<16384).map { index in
            if noise { return UInt8((index * 29 + index / 7) % 256) }
            return index < 8192 ? 129 : 255
        }
        return FrameDetections(ball: ball, person: person, people: [person,ball],
            ballMask: BallMask(rect: CGRect(x: 0.32, y: 0.58, width: 0.1, height: 0.06), width: 128, height: 128, alpha: alpha,
                decoderPixelSize: CGSize(width: 1.0/72, height: 1.0/72)), usesBallMasks: true)
    }
    func testAllFramesSurviveTinyRAMWindowAndReopening() throws {
        do {
            let cache = RFFramePredictionCache(byteLimit: 512, disk: try disk())
            for i in 0..<150 { try cache.store(i%2 == 0 ? value() : FrameDetections(ball: nil, person: nil, usesBallMasks: true), for: key(i)) }
            XCTAssertLessThanOrEqual(cache.retainedBytes, 512)
        }
        let cache = RFFramePredictionCache(byteLimit: 0, disk: try disk())
        for i in 0..<150 {
            let got = try XCTUnwrap(cache.lookup(key(i)))
            XCTAssertEqual(got.ball?.score, i%2 == 0 ? 0.8 : nil)
            XCTAssertTrue(got.usesBallMasks)
        }
        XCTAssertEqual(cache.diskHitCount, 150)
        XCTAssertEqual(cache.retainedBytes, 0)
    }
    func testLosslessMaskGeometryEveryAlphaAndPeople() throws {
        for noise in [false,true] {
            let i = noise ? 1 : 0, ref = value(noise: noise)
            try disk().store(ref, for: key(i))
            let got = try XCTUnwrap(disk().lookup(key(i)))
            XCTAssertEqual(got.ball?.x.bitPattern, ref.ball?.x.bitPattern)
            XCTAssertEqual(got.ball?.score.bitPattern, ref.ball?.score.bitPattern)
            XCTAssertEqual(got.people.map(\.x), ref.people.map(\.x))
            XCTAssertEqual(got.person?.score, ref.person?.score)
            XCTAssertEqual(got.ballMask?.alpha, ref.ballMask?.alpha)
            XCTAssertEqual(got.ballMask?.rect, ref.ballMask?.rect)
            XCTAssertEqual(got.ballMask?.decoderPixelSize, ref.ballMask?.decoderPixelSize)
        }
    }
    func testDifferentInputsModelBackendThresholdGeometrySourceAndRuntimeMiss() throws {
        let d = try disk(); try d.store(value(), for: key())
        for k in [key(1),key(model:"new-weights"),key(cpu:true),key(threshold:0.5),key(width:1080)] { XCTAssertNil(try d.lookup(k)) }
        XCTAssertNil(try disk(source:"another-source").lookup(key()))
        XCTAssertNil(try disk(runtime:"another-runtime").lookup(key()))
        XCTAssertNotNil(try disk().lookup(key()))
    }
    func testCommittedValueWinsDuplicateInsertIncludingRAM() throws {
        try disk().store(value(0.8), for: key())
        let cache = RFFramePredictionCache(disk: try disk())
        try cache.store(value(0.9), for: key())
        XCTAssertEqual(try cache.lookup(key())?.ball?.score, 0.8)
        XCTAssertEqual(try disk().lookup(key())?.ball?.score, 0.8)
    }
    func testCorruptPayloadFailsVisiblyInsteadOfAFalseHitOrSilentMiss() throws {
        let d = try disk(); try d.store(value(), for: key())
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("predictions.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE predictions SET payload=x'010203'", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try d.lookup(key()))
    }
    func testFullDatabaseThrowsAndPreviouslyCommittedResultsRemainReadable() throws {
        let d = try disk(limit: 64*1024)
        var committed = 0, failed = false
        for i in 0..<30 {
            do { try d.store(value(noise:true), for: key(i)); committed += 1 }
            catch { failed = true; break }
        }
        XCTAssertTrue(failed); XCTAssertGreaterThan(committed, 0)
        for i in 0..<committed { XCTAssertNotNil(try d.lookup(key(i))) }
        XCTAssertNil(try d.lookup(key(committed)))
    }
    func testClearingRAMDoesNotDeleteDurableResults() throws {
        let cache = RFFramePredictionCache(disk: try disk())
        try cache.store(value(), for: key()); cache.removeAll()
        XCTAssertNotNil(try cache.lookup(key())); XCTAssertEqual(cache.diskHitCount, 1)
    }
}
