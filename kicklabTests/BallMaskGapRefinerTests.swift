import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import kicklab

final class BallMaskGapRefinerTests: XCTestCase {
    private func anchors() throws -> [Int:RecordedFrame] {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"hand-mask-gap-anchors",withExtension:"json"))
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [[String:Any]]
        return Dictionary(uniqueKeysWithValues:rows.map {row in
            let b=row["ball"] as! [Double],m=row["mask"] as! [String:Any],r=m["rect"] as! [Double]
            let mask=BallMask(rect:CGRect(x:r[0],y:r[1],width:r[2],height:r[3]),width:m["width"] as! Int,height:m["height"] as! Int,alpha:Array(Data(base64Encoded:m["alpha"] as! String)!))
            return (row["frame"] as! Int,RecordedFrame(time:row["time"] as! Double,x:b[1],y:b[2],width:b[3],height:b[4],score:b[0],smoothedX:b[1],smoothedY:b[2],vy:0,motion:.unknown,detected:true,person:nil,ballMask:mask,usesBallMasks:true))
        })
    }
    private func pixels(_ index:Int,context:CIContext) throws -> CVPixelBuffer {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"hand-mask-gap-\(index)",withExtension:"jpg"))
        let image=try XCTUnwrap(CIImage(contentsOf:url,options:[.applyOrientationProperty:true]))
        var buffer:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,720,1280,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer),kCVReturnSuccess)
        context.render(image,to:buffer!);return buffer!
    }
    func testActualHandGapsRecoverWithoutCoveringHandOrChangingMotion() throws {
        let values=try anchors(),context=CIContext(options:[.workingColorSpace:NSNull(),.cacheIntermediates:false])
        var reports=[[String:Any]]()
        for i in [101,106] {
            let a=values[i-1]!,b=values[i+1]!,request=BallMaskGapRefiner.Request(before:a,after:b)
            let before=try pixels(i-1,context:context),current=try pixels(i,context:context),after=try pixels(i+1,context:context)
            let result=try XCTUnwrap(BallMaskGapRefiner.recover(before:before,current:current,after:after,request:request,context:context))
            XCTAssertLessThanOrEqual(result.mask.alpha.count,128*128)
            XCTAssertEqual(result.mask.coverage(x:0.1,y:0.1),0)
            // Independently reviewed source points: the central hand cutout,
            // and the visible lower/right ball surface.
            let hand=i==101 ? CGPoint(x:370,y:902):CGPoint(x:370,y:818)
            let ball=i==101 ? CGPoint(x:415,y:972):CGPoint(x:421,y:863)
            XCTAssertLessThan(result.mask.coverage(x:hand.x/720,y:hand.y/1280),0.25)
            XCTAssertGreaterThan(result.mask.coverage(x:ball.x/720,y:ball.y/1280),0.65)
            let repair=RecordedFrame(time:request.time,x:(a.x+b.x)/2,y:(a.y+b.y)/2,width:(a.width+b.width)/2,height:(a.height+b.height)/2,score:min(a.score,b.score),smoothedX:0,smoothedY:0,vy:0,motion:.unknown,detected:true,person:nil,ballMask:result.mask,usesBallMasks:true,isVisualMaskRepair:true)
            let original=BallEffectTrack(frames:[a,b]),refined=BallEffectTrack(frames:[a,repair,b])
            XCTAssertEqual(original.samples.count,refined.samples.count)
            for (x,y) in zip(original.samples,refined.samples) {XCTAssertEqual(x.center,y.center);XCTAssertEqual(x.boxSize,y.boxSize);XCTAssertEqual(x.time,y.time)}
            XCTAssertNotNil(refined.mask(at:request.time));XCTAssertNil(refined.mask(at:request.time+0.004))
            XCTAssertEqual(refined.mask(at:a.time)?.alpha,a.ballMask?.alpha)
            reports.append(["frame":i,"agreement":result.agreement,"photometric_error":result.photometricError,"consistent_fraction":result.consistentFraction,"mask_bytes":result.mask.alpha.count])
        }
        try JSONSerialization.data(withJSONObject:reports,options:.prettyPrinted).write(to:URL.documentsDirectory.appendingPathComponent("hand-mask-gap-test.json"))
    }
    func testSceneCutOrCoveredBallCannotBeFilledFromNeighbourMasks() throws {
        let values=try anchors(),context=CIContext(options:[.workingColorSpace:NSNull(),.cacheIntermediates:false])
        let a=values[100]!,b=values[102]!,before=try pixels(100,context:context),after=try pixels(102,context:context)
        let current=try pixels(101,context:context)
        context.render(CIImage(color:CIColor(red:0.15,green:0.65,blue:0.25)).cropped(to:CGRect(x:0,y:0,width:720,height:1280)),to:current)
        XCTAssertNil(try BallMaskGapRefiner.recover(before:before,current:current,after:after,request:.init(before:a,after:b),context:context))
        let source=try pixels(101,context:context)
        let covered=CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5)).cropped(to:CGRect(x:270,y:1280-1100,width:270,height:340)).composited(over:CIImage(cvPixelBuffer:source))
        context.render(covered,to:current)
        XCTAssertNil(try BallMaskGapRefiner.recover(before:before,current:current,after:after,request:.init(before:a,after:b),context:context))
    }
    func testPolicyNeverExtendsEndpointsLongGapsOrRecoveredMasks() throws {
        let values=try anchors(),a=values[100]!,b=values[102]!
        XCTAssertEqual(BallMaskGapRefiner.requests(frames:[a,b],frameDuration:1.0/60).count,1)
        XCTAssertTrue(BallMaskGapRefiner.requests(frames:[a],frameDuration:1.0/60).isEmpty)
        // Up to three missing frames are repaired, each at its own composition time.
        let three=BallMaskGapRefiner.requests(frames:[a,b],frameDuration:1.0/120)
        XCTAssertEqual(three.count,3)
        XCTAssertEqual(three.map(\.time),(1...3).map {a.time+Double($0)*(b.time-a.time)/4})
        XCTAssertTrue(BallMaskGapRefiner.requests(frames:[a,b],frameDuration:1.0/240).isEmpty, "Seven missing frames is too long")
        XCTAssertTrue(BallMaskGapRefiner.requests(frames:[a,b],frameDuration:.nan).isEmpty)
        var recovered=a;recovered.isVisualMaskRepair=true
        XCTAssertTrue(BallMaskGapRefiner.requests(frames:[recovered,b],frameDuration:1.0/60).isEmpty)
        var empty=a;empty.ballMask=nil
        XCTAssertTrue(BallMaskGapRefiner.requests(frames:[empty,b],frameDuration:1.0/60).isEmpty)
        let far=values[107]!
        XCTAssertTrue(BallMaskGapRefiner.requests(frames:[a,far],frameDuration:1.0/60).isEmpty)
    }
    func testBallTouchingTheFrameEdgeIsStillEligible() throws {
        // Re-entry through the top edge clips the box; the image checks still decide.
        let values=try anchors();var a=values[100]!,b=values[102]!
        a=RecordedFrame(time:a.time,x:a.x,y:a.height/2,width:a.width,height:a.height,score:a.score,smoothedX:a.x,smoothedY:a.height/2,
            vy:0,motion:.unknown,detected:true,person:nil,ballMask:a.ballMask,usesBallMasks:true)
        b=RecordedFrame(time:b.time,x:b.x,y:b.height/2,width:b.width,height:b.height*1.9,score:b.score,smoothedX:b.x,smoothedY:b.height/2,
            vy:0,motion:.unknown,detected:true,person:nil,ballMask:b.ballMask,usesBallMasks:true)
        XCTAssertEqual(BallMaskGapRefiner.requests(frames:[a,b],frameDuration:1.0/60).count,1)
    }

    func testNearlySolidRectangleIsNotEvidenceOfABallSilhouette() throws {
        let values=try anchors();var a=values[100]!,b=values[102]!
        let original=a.ballMask!
        let rectangle=BallMask(rect:original.rect,width:original.width,height:original.height,
            alpha:Array(repeating:255,count:original.width*original.height))
        a.ballMask=rectangle;b.ballMask=rectangle
        XCTAssertTrue(BallMaskGapRefiner.requests(frames:[a,b],frameDuration:1.0/60).isEmpty)
        let context=CIContext(options:[.workingColorSpace:NSNull()])
        XCTAssertNil(try BallMaskGapRefiner.recover(before:pixels(100,context:context),current:pixels(101,context:context),
            after:pixels(102,context:context),request:.init(before:a,after:b),context:context))
    }
    func testCancellationPropagatesBeforeOpeningSource() async throws {
        let task=Task { try await BallMaskGapRefiner.refine(source:URL(fileURLWithPath:"/missing.mov"),frames:[]) }
        task.cancel()
        do {_ = try await task.value;XCTFail("Expected cancellation")}
        catch is CancellationError {}
    }
}
