import CoreImage
import CoreML
import CoreVideo
import XCTest
@testable import kicklab

final class RFSegBridgeTests: XCTestCase {
    private final class WeakBuffer {
        weak var value: CVPixelBuffer?
        init(_ value: CVPixelBuffer) { self.value = value }
    }

    func testChangingCropSizesReleasesEverySupersededPixelBuffer() throws {
        var observed: [WeakBuffer] = []
        try autoreleasepool {
            let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            let bridge = RFSegBridge()
            // Match preparation's changing crop dimensions, including returning
            // to an earlier size. Same-size frames must reuse the current buffer.
            for side in [128, 256, 192, 384, 128, 256] {
                try autoreleasepool {
                    let image = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7))
                        .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
                    _ = try bridge.input(image: image, context: context)
                    let buffer = try XCTUnwrap(bridge.inputBufferForReview)
                    observed.append(WeakBuffer(buffer))
                    _ = try bridge.input(image: image, context: context)
                    XCTAssertTrue(buffer === bridge.inputBufferForReview)
                }
            }
            context.clearCaches()
        }
        XCTAssertEqual(observed.count, 6)
        XCTAssertTrue(observed.allSatisfy { $0.value == nil },
                      "Changing crop dimensions must not strand earlier Core Video buffers")
    }

    private func array(_ shape: [NSNumber], fill: Float, type: MLMultiArrayDataType) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape, dataType: type)
        if type == .float16 {
            result.dataPointer.assumingMemoryBound(to: Float16.self).initialize(repeating: Float16(fill), count: result.count)
        } else {
            result.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: fill, count: result.count)
        }
        return result
    }

    private func output(ballLogit: Float = 2, type: MLMultiArrayDataType = .float32) throws -> MLFeatureProvider {
        let boxes = try array([1, 100, 4], fill: 0, type: type)
        let scores = try array([1, 100, 91], fill: -50, type: type)
        let masks = try array([1, 100, 96, 96], fill: -1, type: type)
        // The ball and person occupy separate queries and COCO categories.
        for (i, value) in [0.95, 0.5, 0.2, 0.1].enumerated() { boxes[[0, 9, NSNumber(value: i)]] = NSNumber(value: value) }
        for (i, value) in [0.4, 0.5, 0.4, 0.8].enumerated() { boxes[[0, 3, NSNumber(value: i)]] = NSNumber(value: value) }
        scores[[0, 9, 37]] = NSNumber(value: ballLogit)
        scores[[0, 3, 1]] = 4
        for i in (9 * 96 * 96)..<(10 * 96 * 96) { masks[i] = 1 }
        return try MLDictionaryFeatureProvider(dictionary: ["concat_2": boxes, "linear_122": scores, "add_62": masks])
    }

    func testDecodesSeparateClassesClippedSourceBoxAndOwnedMask() throws {
        let result = try RFSegBridge().decode(output(), sourceSize: CGSize(width: 720, height: 1280), threshold: 0.4)
        let ball = try XCTUnwrap(result.ball), person = try XCTUnwrap(result.person)
        XCTAssertEqual(ball.score, 0.880797, accuracy: 0.00001)
        XCTAssertEqual(ball.x, 0.925, accuracy: 0.00001)
        XCTAssertEqual(ball.width, 0.15, accuracy: 0.00001)
        XCTAssertEqual(ball.y, 0.5, accuracy: 0.00001)
        XCTAssertEqual(person.x, 0.4, accuracy: 0.00001)
        let mask = try XCTUnwrap(result.ballMask)
        XCTAssertEqual(mask.alpha.count, mask.width * mask.height)
        XCTAssertLessThanOrEqual(mask.alpha.count, 128 * 128)
        XCTAssertTrue(mask.alpha.contains { $0 > 0 })
        XCTAssertTrue(result.usesBallMasks)
    }

    func testMultiplePeopleDeduplicateQueriesWithoutChangingBallOrMask() throws {
        let features = try output()
        let boxes = try XCTUnwrap(features.featureValue(for: "concat_2")?.multiArrayValue)
        let scores = try XCTUnwrap(features.featureValue(for: "linear_122")?.multiArrayValue)
        for (query, x) in [(4, 0.401), (5, 0.85)] {
            for (i,value) in [x,0.5,0.2,0.8].enumerated() { boxes[[0,NSNumber(value:query),NSNumber(value:i)]] = NSNumber(value:value) }
            scores[[0,NSNumber(value:query),1]] = 3
        }
        // Query 4 duplicates query 3's exact width as well.
        boxes[[0,4,2]] = 0.4
        let result = try RFSegBridge().decode(features,sourceSize:CGSize(width:720,height:1280),threshold:0.4)
        XCTAssertEqual(result.people.count,2)
        XCTAssertEqual(result.people[0].x,0.4,accuracy:0.0001)
        XCTAssertEqual(result.people[1].x,0.85,accuracy:0.0001)
        XCTAssertEqual(try XCTUnwrap(result.ball).x,0.925,accuracy:0.0001)
        XCTAssertNotNil(result.ballMask)
        let crop = try RFSegBridge().decode(features,sourceSize:CGSize(width:720,height:1280),threshold:0.4,includeAuxiliary:false)
        XCTAssertTrue(crop.people.isEmpty)
    }

    func testRejectedBallDoesNotProduceMaskOrDiscardPerson() throws {
        for logit: Float in [-0.5, .infinity, .nan] {
            let result = try RFSegBridge().decode(output(ballLogit: logit), sourceSize: CGSize(width: 720, height: 1280), threshold: 0.4)
            XCTAssertNil(result.ball)
            XCTAssertNil(result.ballMask)
            XCTAssertNotNil(result.person)
        }
    }

    func testWallOnlyDecodeKeepsTheSameBallWithoutBuildingAuxiliaryResults() throws {
        let bridge = RFSegBridge(), size = CGSize(width: 1280, height: 720)
        for type: MLMultiArrayDataType in [.float16, .float32] {
            let features = try output(type: type)
            let full = try bridge.decode(features, sourceSize: size, threshold: 0.2)
            let wall = try bridge.decode(features, sourceSize: size, threshold: 0.2, includeAuxiliary: false)
            let fullBall = try XCTUnwrap(full.ball), wallBall = try XCTUnwrap(wall.ball)
            XCTAssertEqual(wallBall.score, fullBall.score)
            XCTAssertEqual(wallBall.x, fullBall.x)
            XCTAssertEqual(wallBall.y, fullBall.y)
            XCTAssertEqual(wallBall.width, fullBall.width)
            XCTAssertEqual(wallBall.height, fullBall.height)
            XCTAssertNil(wall.person)
            XCTAssertNil(wall.ballMask)
            XCTAssertFalse(wall.usesBallMasks)
        }
    }

    func testWrongOutputContractFailsInsteadOfInventingDetections() throws {
        let empty = try MLDictionaryFeatureProvider(dictionary: [:])
        XCTAssertThrowsError(try RFSegBridge().decode(empty, sourceSize: CGSize(width: 720, height: 1280), threshold: 0.4))
    }

    func testWallHandCheckKeepsPersonWithoutBuildingMask() throws {
        let bridge = RFSegBridge(), size = CGSize(width: 1280, height: 720)
        for type: MLMultiArrayDataType in [.float16, .float32] {
            let features = try output(type: type)
            let full = try bridge.decode(features, sourceSize: size, threshold: 0.2)
            let wall = try bridge.decode(features, sourceSize: size, threshold: 0.2, includeMasks: false)
            XCTAssertEqual(wall.ball?.x, full.ball?.x)
            XCTAssertEqual(wall.person?.x, full.person?.x)
            XCTAssertNotNil(wall.person)
            XCTAssertNil(wall.ballMask)
            XCTAssertFalse(wall.usesBallMasks)
        }
    }

    func testHalfPrecisionDecodesClassesAndMaskWithoutMovingConfidenceThreshold() throws {
        let bridge = RFSegBridge(), size = CGSize(width: 720, height: 1280)
        for type: MLMultiArrayDataType in [.float16, .float32] {
            // Sigmoid(-0.405) is just above 0.40; -0.406 is just below.
            let accepted = try bridge.decode(output(ballLogit: -0.405, type: type), sourceSize: size, threshold: 0.4)
            XCTAssertNotNil(accepted.ball)
            XCTAssertNotNil(accepted.ballMask)
            XCTAssertEqual(try XCTUnwrap(accepted.ball).x, 0.925, accuracy: 0.0005)
            XCTAssertEqual(try XCTUnwrap(accepted.person).x, 0.4, accuracy: 0.0005)
            let rejected = try bridge.decode(output(ballLogit: -0.406, type: type), sourceSize: size, threshold: 0.4)
            XCTAssertNil(rejected.ball)
            XCTAssertNil(rejected.ballMask)
            XCTAssertNotNil(rejected.person)
        }
    }

    func testTrainingNormalizationUsesRGBAndSkipsRowPadding() {
        var source = [UInt8](repeating: 255, count: 24)
        for y in 0..<2 { for x in 0..<2 {
            source[y*12+x*4] = 25
            source[y*12+x*4+1] = 80
            source[y*12+x*4+2] = 150
        } }
        let plane = 384 * 384
        var values = [Float](repeating: 0, count: plane * 3)
        source.withUnsafeBufferPointer { bytes in values.withUnsafeMutableBufferPointer { output in
            RFInputNormalization.normalizeBGRA(bytes.baseAddress!, width: 2, height: 2, rowBytes: 12, into: output.baseAddress!)
        } }
        let rgb: [Float] = [150, 80, 25], mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        for c in 0..<3 { for pixel in [0, 383, plane/2, plane-1] {
            XCTAssertEqual(values[c*plane+pixel], (rgb[c]/255-mean[c])/std[c], accuracy: 0.000001)
        } }
    }

    func testWallCropReadsTopLeftSourceRowsWithoutChangingRGBNormalization() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 12, 10, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        bytes.initialize(repeating: 0, count: stride * 10)
        for y in 3..<5 { for x in 2..<5 {
            bytes[y*stride+x*4] = 25; bytes[y*stride+x*4+1] = 80; bytes[y*stride+x*4+2] = 150
            bytes[y*stride+x*4+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let input = try RFSegBridge().wallInput(pixels, crop: CGRect(x: 2, y: 3, width: 3, height: 2))
        let array = try XCTUnwrap(input.featureValue(for: "tensors")?.multiArrayValue)
        let rgb: [Float] = [150, 80, 25], mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        for c in 0..<3 { for i in [0, 383, 384*384-1] {
            XCTAssertEqual(array[c*384*384+i].floatValue, (rgb[c]/255-mean[c])/std[c], accuracy: 0.000001)
        } }
    }

    func testWallCandidatesRetainMeasuredWeakBoxesForTemporalAssociation() throws {
        let bridge = RFSegBridge()
        let weak = try bridge.wallCandidates(output(ballLogit: -2))
        XCTAssertEqual(weak.count, 1)
        XCTAssertEqual(try XCTUnwrap(weak.first).score, 0.119203, accuracy: 0.00001)
        XCTAssertTrue(try bridge.wallCandidates(output(ballLogit: .nan)).isEmpty)
        XCTAssertTrue(try bridge.wallCandidates(output(ballLogit: -4)).isEmpty)
    }
}
