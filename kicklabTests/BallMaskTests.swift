import CoreML
import XCTest
@testable import kicklab

final class BallMaskTests: XCTestCase {
    func testSeparableCoverageMatchesTwoDimensionalKernelAtEdgesAndAllSizes() {
        var state: UInt64 = 0xB411
        for (w, h) in [(1,1), (1,8), (8,1), (8,8), (17,31), (64,97), (128,128)] {
            for mode in 0..<4 {
                let binary: [UInt8] = (0..<w*h).map { i in
                    state = state &* 6364136223846793005 &+ 1
                    switch mode {
                    case 0: return 0
                    case 1: return 255
                    case 2: return (state >> 32) % 7 == 0 ? 255 : 0
                    default: return UInt8(truncatingIfNeeded: state >> 32)
                    }
                }
                var expanded = binary, expected = binary
                for y in 0..<h { for x in 0..<w {
                    expanded[y*w+x] = (max(0,y-1)...min(h-1,y+1)).flatMap { yy in
                        (max(0,x-1)...min(w-1,x+1)).map { binary[yy*w+$0] }
                    }.max()!
                } }
                for y in 0..<h { for x in 0..<w {
                    var sum = 0
                    for dy in -1...1 { for dx in -1...1 {
                        let yy = y+dy, xx = x+dx
                        if yy >= 0, yy < h, xx >= 0, xx < w {
                            sum += Int(expanded[yy*w+xx]) * (dy == 0 ? 2 : 1) * (dx == 0 ? 2 : 1)
                        }
                    } }
                    expected[y*w+x] = UInt8(sum/16)
                } }
                XCTAssertEqual(BallMask.featheredCoverage(binary, width: w, height: h), expected,
                               "Coverage changed for \(w)×\(h), pattern \(mode)")
            }
        }
    }

    private func output(maskValue: Float) throws -> MLFeatureProvider {
        let boxes = try MLMultiArray(shape: [1, 4], dataType: .float32)
        for (i, v) in [280, 320, 360, 400].enumerated() { boxes[i] = NSNumber(value: v) }
        let scores = try MLMultiArray(shape: [1], dataType: .float32); scores[0] = 0.9
        let labels = try MLMultiArray(shape: [1], dataType: .float32); labels[0] = 37
        let coefficients = try MLMultiArray(shape: [1, 32], dataType: .float32)
        for i in 0..<32 { coefficients[i] = i == 0 ? 1 : 0 }
        let prototypes = try MLMultiArray(shape: [32, 160, 160], dataType: .float32)
        let p = prototypes.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<prototypes.count { p[i] = i < 25600 ? maskValue : 0 }
        return try MLDictionaryFeatureProvider(dictionary: ["boxes": boxes, "scores": scores, "labels": labels,
            "mask_coefficients": coefficients, "mask_prototypes": prototypes])
    }

    func testEmptyMaskPreservesConfidentBallBox() throws {
        let out = try output(maskValue: -10)
        let content = CGRect(x: 0.21875, y: 0, width: 0.5625, height: 1)
        XCTAssertNil(BallMask.decode(out, content: content, sourceSize: CGSize(width: 720, height: 1280), threshold: 0.3))
        let box = try BallDetector.decodedValues(out, width: 640, height: 640, clipTo: content)
        XCTAssertEqual(box[0], 0.9, accuracy: 0.0001)
        XCTAssertGreaterThan(box[3], 0)
    }

    func testCropBorderLetsAnObservedCircleReconstructWithoutInventingEmptyCoverage() throws {
        let out = try output(maskValue: -10)
        let prototypes = try XCTUnwrap(out.featureValue(for: "mask_prototypes")?.multiArrayValue)
        let p = prototypes.dataPointer.assumingMemoryBound(to: Float.self)
        // A known circle touches the selected box. The border must expose its
        // actual negative logits so the silhouette fit can see the whole rim.
        for y in 0..<160 { for x in 0..<160 {
            p[y*160+x] = Float(10 - hypot(Double(x)+0.5-80, Double(y)+0.5-90))*10
        } }
        let size = CGSize(width:160,height:160), content = CGRect(x:0,y:0,width:1,height:1)
        let mask = try XCTUnwrap(BallMask.decode(out,content:content,sourceSize:size,threshold:0.5,sourceBorder:4))
        let coverage = BallReplacementCoverage(mask:mask,fitted:nil,size:size)
        XCTAssertTrue(coverage.reconstructsBody)
        XCTAssertEqual(coverage.footprint.center.x,80,accuracy:1)
        XCTAssertEqual(coverage.footprint.center.y,90,accuracy:1)
        XCTAssertEqual(coverage.footprint.radius,10,accuracy:1.5)
        XCTAssertLessThan(mask.coverage(x:mask.rect.minX+0.01,y:mask.rect.minY+0.01),0.1)
        XCTAssertNil(BallMask.decode(try output(maskValue:-10),content:content,sourceSize:size,
                                    threshold:0.5,sourceBorder:4))
    }

    func testMaskUnletterboxingCoverageAndBoundedStorage() throws {
        let mask = try XCTUnwrap(BallMask.decode(output(maskValue: 10),
            content: CGRect(x: 0.21875, y: 0, width: 0.5625, height: 1),
            sourceSize: CGSize(width: 2160, height: 3840), threshold: 0.3))
        XCTAssertEqual(mask.rect.midX, 0.5, accuracy: 0.00001)
        XCTAssertEqual(mask.rect.midY, 0.5625, accuracy: 0.00001)
        XCTAssertEqual(mask.coverage(x: 0.5, y: 0.5625), 1, accuracy: 0.001)
        XCTAssertEqual(mask.coverage(x: 0.1, y: 0.1), 0)
        XCTAssertLessThanOrEqual(mask.alpha.count, 128*128)
    }

    func testSelectedCandidateUsesItsOwnMaskAndEmptyMaskKeepsBox() throws {
        let original=try output(maskValue: 10)
        let boxes=try MLMultiArray(shape:[2,4],dataType:.float32)
        for (i,v) in [100,100,180,180,400,400,480,480].enumerated() { boxes[i]=NSNumber(value:v) }
        let scores=try MLMultiArray(shape:[2],dataType:.float32); scores[0]=0.9; scores[1]=0.4
        let labels=try MLMultiArray(shape:[2],dataType:.float32); labels[0]=37; labels[1]=37
        let coefficients=try MLMultiArray(shape:[2,32],dataType:.float32)
        for i in 0..<64 { coefficients[i]=i == 0 || i == 32 ? 1 : 0 }
        let out=try MLDictionaryFeatureProvider(dictionary:["boxes":boxes,"scores":scores,"labels":labels,
            "mask_coefficients":coefficients,"mask_prototypes":original.featureValue(for:"mask_prototypes")!])
        let selected=try XCTUnwrap(BallMask.decode(out,content:CGRect(x:0,y:0,width:1,height:1),
            sourceSize:CGSize(width:640,height:640),threshold:0.3,selectedIndex:1))
        XCTAssertEqual(selected.rect.midX,440.0/640,accuracy:1e-8)
        XCTAssertEqual(selected.rect.midY,440.0/640,accuracy:1e-8)
        coefficients[32] = -1
        XCTAssertNil(BallMask.decode(out,content:CGRect(x:0,y:0,width:1,height:1),
            sourceSize:CGSize(width:640,height:640),threshold:0.3,selectedIndex:1))
    }

    func testMaskIsNeverHeldAcrossMissingFrames() {
        let mask = BallMask(rect: CGRect(x: 0.4,y: 0.4,width: 0.2,height: 0.2), width: 8,height: 8,alpha: Array(repeating: 255,count: 64))
        let frame = RecordedFrame(time: 1,x: 0.5,y: 0.5,width: 0.2,height: 0.2,score: 0.9,
            smoothedX: 0.5,smoothedY: 0.5,vy: 0,motion: .unknown,detected: true,person: nil,ballMask: mask,usesBallMasks: true)
        let track = BallEffectTrack(frames: [frame])
        XCTAssertNotNil(track.mask(at: 1.001))
        XCTAssertNil(track.mask(at: 1.02))
        XCTAssertNil(track.mask(at: 2))
        XCTAssertTrue(track.usesBallMasks)
        XCTAssertEqual(BallDetector.resourceName(for: ["--yolo26-medium-segmentation"]), "KickLabYOLO26MediumSegmentation")
        XCTAssertEqual(BallDetector.resourceName(for: ["--yolo26-medium-segmentation", "--ssdlite"]), "KickLabDetector")
    }
}
