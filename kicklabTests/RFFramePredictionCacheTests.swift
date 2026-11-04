import CoreGraphics
import CoreML
import XCTest
@testable import kicklab

final class RFFramePredictionCacheTests: XCTestCase {
    private func input(_ value: Float = 0, size: CGSize = CGSize(width: 720, height: 1280)) throws -> RFFramePredictionCache.Input {
        let tensor = try MLMultiArray(shape: [1, 3, 4, 4], dataType: .float32)
        for i in 0..<tensor.count { tensor[i] = NSNumber(value: value) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["tensors": tensor])
        return try XCTUnwrap(RFFramePredictionCache.input(provider, sourceSize: size))
    }
    private func key(_ value: Float = 0, model: String = "rf288", cpu: Bool = false,
                     threshold: Double = 0.4, size: CGSize = CGSize(width: 720, height: 1280)) throws -> RFFramePredictionCache.Key {
        .init(input: try input(value, size: size), model: model, cpuOnly: cpu, threshold: threshold)
    }

    func testReuseRequiresExactTensorModelBackendThresholdAndGeometry() throws {
        let cache = RFFramePredictionCache()
        let original = try key()
        cache.store(FrameDetections(ball: Detection(score: 0.8, x: 0.5, y: 0.3, width: 0.1, height: 0.06), person: nil), for: original)
        XCTAssertNotNil(cache.lookup(try key()))
        for different in [try key(Float.leastNonzeroMagnitude), try key(model: "rf384"), try key(cpu: true),
                          try key(threshold: 0.5), try key(size: CGSize(width: 1080, height: 1920))] {
            XCTAssertNil(cache.lookup(different))
        }
    }

    func testSuccessfulMissAndAllPeopleSurviveReuse() throws {
        let cache = RFFramePredictionCache(), key = try key()
        let people = [Detection(score: 0.7, x: 0.1, y: 0.4, width: 0.1, height: 0.5),
                      Detection(score: 0.9, x: 0.8, y: 0.4, width: 0.2, height: 0.5)]
        cache.store(FrameDetections(ball: nil, person: people[1], people: people, usesBallMasks: true), for: key)
        let reused = try XCTUnwrap(cache.lookup(key))
        XCTAssertNil(reused.ball)
        XCTAssertEqual(reused.people.map(\.x), [0.1, 0.8])
        XCTAssertEqual(reused.person?.score, 0.9)
        XCTAssertTrue(reused.usesBallMasks)
    }

    func testCompactStoragePreservesEveryMaskByteAndSamplingGeometry() throws {
        let mask = BallMask(rect: CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.1), width: 16, height: 16,
            alpha: Array(repeating: 0, count: 64) + Array(repeating: 129, count: 128) + Array(repeating: 255, count: 64),
            decoderPixelSize: CGSize(width: 1.0 / 72, height: 1.0 / 72))
        let cache = RFFramePredictionCache(), key = try key()
        cache.store(FrameDetections(ball: nil, person: nil, ballMask: mask, usesBallMasks: true), for: key)
        let reused = try XCTUnwrap(cache.lookup(key)?.ballMask)
        XCTAssertEqual(reused.alpha, mask.alpha)
        XCTAssertEqual(reused.rect, mask.rect)
        XCTAssertEqual(reused.decoderPixelSize, mask.decoderPixelSize)
        XCTAssertLessThan(reused.storageByteCount, mask.storageByteCount)
    }

    func testMemoryBudgetKeepsEarlierPredictionsAndCanBeCleared() throws {
        let cache = RFFramePredictionCache(byteLimit: 600)
        let keys = try [key(0), key(1), key(2)]
        for key in keys { cache.store(FrameDetections(ball: nil, person: nil), for: key) }
        XCTAssertNotNil(cache.lookup(keys[0]))
        XCTAssertNotNil(cache.lookup(keys[1]))
        XCTAssertNil(cache.lookup(keys[2]))
        XCTAssertLessThanOrEqual(cache.retainedBytes, 600)
        cache.removeAll()
        XCTAssertNil(cache.lookup(keys[0])); XCTAssertEqual(cache.retainedBytes, 0)
    }

    /// A clip over the budget used to reuse nothing: each second-pass miss evicted the next hit.
    func testASecondPassOverAClipLargerThanTheBudgetStillReusesItsStart() throws {
        let cache = RFFramePredictionCache(byteLimit: 900)
        let counted = try (0..<6).map { try key(Float($0) * 2) }, inBetween = try (0..<6).map { try key(Float($0) * 2 + 1) }
        for key in counted { cache.store(FrameDetections(ball: nil, person: nil), for: key) }
        var hits = 0
        for (hit, miss) in zip(counted, inBetween) {
            if cache.lookup(hit) != nil { hits += 1 } else { cache.store(FrameDetections(ball: nil, person: nil), for: hit) }
            if cache.lookup(miss) == nil { cache.store(FrameDetections(ball: nil, person: nil), for: miss) }
        }
        XCTAssertEqual(hits, 3)
    }

    func testAClipWithinTheBudgetReusesEveryCountedFrame() throws {
        let cache = RFFramePredictionCache(byteLimit: 2_000)
        let counted = try (0..<6).map { try key(Float($0) * 2) }, inBetween = try (0..<6).map { try key(Float($0) * 2 + 1) }
        for key in counted { cache.store(FrameDetections(ball: nil, person: nil), for: key) }
        var hits = 0
        for (hit, miss) in zip(counted, inBetween) {
            if cache.lookup(hit) != nil { hits += 1 }
            if cache.lookup(miss) == nil { cache.store(FrameDetections(ball: nil, person: nil), for: miss) }
        }
        XCTAssertEqual(hits, 6)
    }

    func testReleasingDropsTheClipsPredictions() throws {
        let owner = RFFramePredictionReuse(), key = try key()
        owner.cache(for: "clip-a|model-v1").store(FrameDetections(ball: nil, person: nil), for: key)
        owner.release()
        XCTAssertNil(owner.cache(for: "clip-a|model-v1").lookup(key))
    }

    func testSourceOrPipelineChangeDoesNotReuseOtherClipPredictions() throws {
        let owner = RFFramePredictionReuse(), key = try key()
        let a = owner.cache(for: "clip-a|model-v1")
        a.store(FrameDetections(ball: nil, person: nil), for: key)
        XCTAssertTrue(a === owner.cache(for: "clip-a|model-v1"))
        XCTAssertNil(owner.cache(for: "clip-b|model-v1").lookup(key))
        XCTAssertNil(owner.cache(for: "clip-a|model-v2").lookup(key))
    }

    func testUnsupportedTensorCannotBecomeAHit() throws {
        let wrong = try MLMultiArray(shape: [1, 3, 4, 4], dataType: .double)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["tensors": wrong])
        XCTAssertNil(RFFramePredictionCache.input(provider, sourceSize: CGSize(width: 720, height: 1280)))
        let normal = try MLMultiArray(shape: [1, 3, 4, 4], dataType: .float32)
        let inputs = try MLDictionaryFeatureProvider(dictionary: ["tensors": normal])
        XCTAssertNil(RFFramePredictionCache.input(inputs, sourceSize: CGSize(width: 720.5, height: 1280)))
        XCTAssertNil(RFFramePredictionCache.input(inputs, sourceSize: CGSize(width: CGFloat.infinity, height: 1280)))
    }
}
