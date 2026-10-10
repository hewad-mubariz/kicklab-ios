import AVFoundation
import UIKit
import XCTest
@testable import kicklab

@MainActor
final class VisualInferenceBatchTests: XCTestCase {
    private func detector() throws -> BallDetector { try BallDetector(resourceName:"KickLabYOLO26MotionSegmentation") }
    private func pixels(_ fixture:String, width:Int, height:Int) throws -> CVPixelBuffer {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:fixture,withExtension:"jpg"))
        let image=try XCTUnwrap(UIImage(contentsOfFile:url.path)?.cgImage)
        var buffer:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer),kCVReturnSuccess)
        let result=try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result,[]);defer {CVPixelBufferUnlockBaseAddress(result,[])}
        let ctx=try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(result),width:width,height:height,bitsPerComponent:8,
            bytesPerRow:CVPixelBufferGetBytesPerRow(result),space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return result
    }
    private func assertSame(_ a:FrameDetections,_ b:FrameDetections,file:StaticString=#filePath,line:UInt=#line) {
        func values(_ d:Detection?)->[Double]? {d.map {[$0.score,$0.x,$0.y,$0.width,$0.height]}}
        XCTAssertEqual(values(a.ball),values(b.ball),file:file,line:line)
        XCTAssertEqual(values(a.person),values(b.person),file:file,line:line)
        XCTAssertEqual(a.ballMask?.rect,b.ballMask?.rect,file:file,line:line)
        XCTAssertEqual(a.ballMask?.width,b.ballMask?.width,file:file,line:line)
        XCTAssertEqual(a.ballMask?.height,b.ballMask?.height,file:file,line:line)
        XCTAssertEqual(a.ballMask?.alpha,b.ballMask?.alpha,file:file,line:line)
        XCTAssertEqual(a.usesBallMasks,b.usesBallMasks,file:file,line:line)
    }
    func testBatchIsOptInAndNeverAppliesToCountedImports() {
        XCTAssertEqual(BallDetector.visualBatchSize(visualOnly:true,arguments:[]),1)
        XCTAssertEqual(BallDetector.visualBatchSize(visualOnly:true,arguments:["--visual-batch2"]),2)
        XCTAssertEqual(BallDetector.visualBatchSize(visualOnly:false,arguments:["--visual-batch2"]),1)
        XCTAssertEqual(BallDetector.visualBatchSize(visualOnly:false,arguments:["--visual-async2"]),1)
        XCTAssertEqual(BallDetector.visualBatchSize(visualOnly:true,arguments:["--visual-batch2","--visual-serial"]),1)
    }
    func testAsyncInputsMatchSerialWithOrderedConsumption() async throws {
        let serial=try detector(),candidate=try detector()
        let a=try pixels("hand-mask-gap-100",width:720,height:1280)
        let b=try pixels("hand-mask-gap-105",width:640,height:360)
        let prepared=try await candidate.prepareBatchAsync([(a,0),(b,1.0/60)])
        for (i,pixel) in [a,b].enumerated() {
            assertSame(try serial.detect(pixel,orientLandscapeAsPortrait:false,timestamp:Double(i)/60),
                       try candidate.detectPrepared(prepared[i]))
            XCTAssertEqual(serial.lastFollowKind,candidate.lastFollowKind)
            XCTAssertEqual(serial.lastFollowCalls,candidate.lastFollowCalls)
        }
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            do { _ = try await candidate.prepareBatchAsync([(a,1)]); XCTFail("Cancelled prediction started") }
            catch {XCTAssertTrue(error is CancellationError)}
        }
        await task.value
    }
    func testIndependentInputsAndPerFrameGeometryMatchSerialIncludingOddTail() throws {
        let serial=try detector(),batch=try detector()
        let frames=[try pixels("hand-mask-gap-100",width:720,height:1280),
                    try pixels("hand-mask-gap-105",width:640,height:360),
                    try pixels("hand-mask-gap-101",width:720,height:1280)]
        for start in stride(from:0,to:frames.count,by:2) {
            let indices=Array(start..<min(start+2,frames.count))
            let prepared=try batch.prepareBatch(indices.map {(pixels:frames[$0],time:Double($0)/60)})
            for (j,i) in indices.enumerated() {
                let reference=try serial.detect(frames[i],orientLandscapeAsPortrait:false,timestamp:Double(i)/60)
                let candidate=try batch.detectPrepared(prepared[j])
                assertSame(reference,candidate)
                XCTAssertEqual(serial.lastFollowKind,batch.lastFollowKind)
                XCTAssertEqual(serial.lastFollowCalls,batch.lastFollowCalls)
            }
        }
    }
    func testWrongOwnerOutOfOrderAndDoubleConsumptionDoNotAdvanceTheBatch() throws {
        let a=try detector(),b=try detector(),pixel=try pixels("hand-mask-gap-100",width:360,height:640)
        let frames=try a.prepareBatch([(pixel,0),(pixel,1.0/60)])
        XCTAssertThrowsError(try b.detectPrepared(frames[0])) {XCTAssertEqual($0 as? BallDetector.BatchError,.wrongDetector)}
        XCTAssertThrowsError(try a.detectPrepared(frames[1])) {XCTAssertEqual($0 as? BallDetector.BatchError,.outOfOrder)}
        _ = try a.detectPrepared(frames[0])
        XCTAssertThrowsError(try a.detectPrepared(frames[0])) {XCTAssertEqual($0 as? BallDetector.BatchError,.consumed)}
        _ = try a.detectPrepared(frames[1])
    }
    func testInvalidBatchesFailBeforeMutatingDetectorHistory() throws {
        let a=try detector(),b=try detector(),pixel=try pixels("hand-mask-gap-101",width:360,height:640)
        for frames:[(pixels:CVPixelBuffer,time:Double)] in [[],[(pixel,.nan)],[(pixel,0),(pixel,0)],[(pixel,1),(pixel,0)],[(pixel,0),(pixel,1),(pixel,2)]] {
            XCTAssertThrowsError(try a.prepareBatch(frames)) {XCTAssertEqual($0 as? BallDetector.BatchError,.invalidFrames)}
        }
        assertSame(try a.detect(pixel,orientLandscapeAsPortrait:false,timestamp:0),try b.detect(pixel,orientLandscapeAsPortrait:false,timestamp:0))
    }
    func testCancellationBeforePreparationAndConsumption() async throws {
        let a=try detector(),pixel=try pixels("hand-mask-gap-100",width:360,height:640)
        let prepared=try a.prepareBatch([(pixel,0)])
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            XCTAssertThrowsError(try a.prepareBatch([(pixel,0)])) {XCTAssertTrue($0 is CancellationError)}
            XCTAssertThrowsError(try a.detectPrepared(prepared[0])) {XCTAssertTrue($0 is CancellationError)}
        }
        try await task.value
        // Cancellation did not mark the pending prediction consumed.
        _ = try a.detectPrepared(prepared[0])
    }
}
