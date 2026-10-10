import AVFoundation
import Metal
import MetalKit
import CoreImage
import simd
import XCTest
@testable import kicklab

@MainActor
final class ReplayMaterialLifecycleTests: XCTestCase {
    func testActualFastBallPreviewMatchesExportMaterialAndCoversUpperLobe() throws {
        let bundle=Bundle(for:Self.self)
        let imageURL=try XCTUnwrap(bundle.url(forResource:"fast-ball-coverage",withExtension:"png"))
        let image=try XCTUnwrap(UIImage(contentsOfFile:imageURL.path)?.cgImage)
        let jsonURL=try XCTUnwrap(bundle.url(forResource:"fast-ball-coverage",withExtension:"json"))
        let document=try JSONSerialization.jsonObject(with:Data(contentsOf:jsonURL)) as! [String:Any]
        let row=document["row"] as! [String:Any],m=row["mask"] as! [String:Any],r=m["rect"] as! [Double]
        let b=row["ball"] as! [Double],time=document["time"] as! Double
        let mask=BallMask(rect:CGRect(x:r[0],y:r[1],width:r[2],height:r[3]),width:m["width"] as! Int,
                          height:m["height"] as! Int,alpha:Array(Data(base64Encoded:m["alpha"] as! String)!))
        // This isolated still has no following observation to interpolate to;
        // stamp its one observation at the exact displayed composition time.
        let frame=RecordedFrame(time:time,x:b[1],y:b[2],width:b[3],height:b[4],score:b[0],
            smoothedX:b[1],smoothedY:b[2],vy:0,motion:.unknown,detected:true,person:nil,ballMask:mask,usesBallMasks:true)
        let q=(document["pose"] as! [String:Any])["q"] as! [Double]
        let pose=simd_quatf(vector:SIMD4(q.map(Float.init)))
        var track=BallEffectTrack(frames:[frame])
        track.surfaceMotion=BallSurfaceTimeline(entries:[.init(time:time,orientation:pose,accepted:true)],elapsed:0)
        let size=CGSize(width:720,height:1280),edit=SessionEditState(style:.none,intensity:0,ballSkin:.galaxy)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let original=scene.windows.first {$0.isKeyWindow},window=UIWindow(windowScene:scene)
        window.rootViewController=UIViewController();window.makeKeyAndVisible()
        let view=EffectVideoView()
        defer {view.stop();window.isHidden=true;window.rootViewController=nil;original?.makeKey()}
        view.frame=CGRect(x:0,y:0,width:360,height:640)
        window.rootViewController!.view.addSubview(view)
        view.drawableSize=size
        var failures=[String]();view.onFailure={failures.append($0)}
        view.configure(image:image,edit:edit,track:track,time:time)
        let drawable=try XCTUnwrap(view.currentDrawable)
        XCTAssertEqual(drawable.texture.width,720);XCTAssertEqual(drawable.texture.height,1280)
        view.draw(view.bounds)
        // Copy after the production preview command on the same serial queue.
        let resources=try MetalEffectEngine.Resources.shared.get()
        let readback=try XCTUnwrap(resources.device.makeBuffer(length:720*1280*4,options:.storageModeShared))
        let command=try XCTUnwrap(resources.queue.makeCommandBuffer()),blit=try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from:drawable.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
            sourceSize:MTLSize(width:720,height:1280,depth:1),to:readback,destinationOffset:0,
            destinationBytesPerRow:720*4,destinationBytesPerImage:720*1280*4)
        blit.endEncoding();command.commit();command.waitUntilCompleted()
        XCTAssertNil(command.error);XCTAssertTrue(failures.isEmpty,failures.joined(separator:"; "))
        let preview=Array(UnsafeBufferPointer(start:readback.contents().assumingMemoryBound(to:UInt8.self),count:720*1280*4))

        // Export's current-frame BGRA path, before H.264 compression.
        var pixels:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,720,1280,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&pixels),kCVReturnSuccess)
        let source=try XCTUnwrap(pixels)
        CIContext(options:[.workingColorSpace:NSNull()]).render(CIImage(cgImage:image),to:source)
        let sample=try XCTUnwrap(track.replacementGuide(at:time))
        let fitted=try XCTUnwrap(BallReplacementFootprint.fit(pixels:source,sample:sample,measureTexture:true))
        let matte=BallReplacementCoverage(mask:mask,fitted:fitted,size:size)
        let patch=try XCTUnwrap(BallMaterialRenderer.replacement(footprint:matte.footprint,skin:.galaxy,time:time,
            coverage:{matte.coverage(x:$0,y:$1)},coverageBounds:matte.bounds,orientation:pose))
        CVPixelBufferLockBaseAddress(source,[])
        defer {CVPixelBufferUnlockBaseAddress(source,[])}
        let stride=CVPixelBufferGetBytesPerRow(source),pointer=CVPixelBufferGetBaseAddress(source)!
        let originalBytes=Array(UnsafeBufferPointer(start:pointer.assumingMemoryBound(to:UInt8.self),count:stride*1280))
        let ctx=try XCTUnwrap(CGContext(data:pointer,width:720,height:1280,bitsPerComponent:8,bytesPerRow:stride,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.translateBy(x:0,y:1280);ctx.scaleBy(x:1,y:-1)
        BallMaterialRenderer.draw(in:ctx,size:size,sourceSize:size,skin:.galaxy,sample:sample,time:time,replacement:patch)
        let export=pointer.assumingMemoryBound(to:UInt8.self)
        var error=0.0,channels=0,lobePixels=0,replacedLobe=0
        for y in 2..<210 {for x in 320..<490 {
            let pi=(y*720+x)*4,ei=y*stride+x*4
            for c in 0..<3 {error += abs(Double(preview[pi+c])-Double(export[ei+c]));channels += 1}
            let dx=Double(x)-fitted.center.x,dy=Double(y)-fitted.center.y
            if mask.coverage(x:Double(x)/720,y:Double(y)/1280)>0.98,
               hypot(dx,dy)>fitted.edge(at:atan2(dy,dx))+fitted.padding+fitted.feather+5 {
                lobePixels += 1
                if (0..<3).map({abs(Int(preview[pi+$0])-Int(originalBytes[ei+$0]))}).max()!>20 {replacedLobe += 1}
            }
        }}
        XCTAssertGreaterThan(lobePixels,100,"Fixture must reproduce the circle-clipping failure")
        XCTAssertGreaterThan(Double(replacedLobe)/Double(max(lobePixels,1)),0.95)
        XCTAssertLessThan(error/Double(channels),3,"Preview and export should agree on matched decoded pixels")
        let report:[String:Any]=["roi_rgb_mae":error/Double(channels),"lobe_pixels":lobePixels,
                                "replaced_lobe_pixels":replacedLobe,"gpu_errors":failures]
        try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted)
            .write(to:URL.documentsDirectory.appendingPathComponent("fast-ball-preview-parity.json"))
    }

    func testRepeatedPlaySeekSkinChangesAndTeardownReleaseMaterialSlots() async throws {
        let url=try XCTUnwrap(Bundle(for:type(of:self)).url(forResource:"juggling-eighteen",withExtension:"mov"))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let original=scene.windows.first {$0.isKeyWindow}
        let window=UIWindow(windowScene:scene)
        window.rootViewController=UIViewController();window.makeKeyAndVisible()
        defer {window.isHidden=true;window.rootViewController=nil;original?.makeKey()}
        let frames=(0..<556).map { i in
            RecordedFrame(time:Double(i)/30,x:0.5,y:0.6,width:0.12,height:0.0675,score:0.9,
                smoothedX:0.5,smoothedY:0.6,vy:0,motion:.unknown,detected:true,person:nil)
        }
        let track=BallEffectTrack(frames:frames)
        var measurements=[[String:Any]]()
        for cycle in 0..<3 {
            let player=AVPlayer(url:url)
            var view: EffectVideoView?=EffectVideoView()
            weak var releasedView: EffectVideoView?
            releasedView = view
            do {
            let current=try XCTUnwrap(view)
            var failures=[String]()
            current.onFailure={ failures.append($0) }
            current.frame=CGRect(x:0,y:0,width:360,height:640)
            window.rootViewController!.view.addSubview(current)
            current.configure(player:player,edit:SessionEditState(style:.none,intensity:0,ballSkin:.gold),track:track)
            player.play()
            try await Task.sleep(for:.milliseconds(900))
            player.pause()
            for time in [4.0,1.0,8.0] {
                await player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
                try await Task.sleep(for:.milliseconds(150))
            }
            XCTAssertTrue(failures.isEmpty,failures.joined(separator:"; "))
            XCTAssertGreaterThan(current.materialAllocationCount,0)
            XCTAssertLessThanOrEqual(current.materialAllocationCount,2,"Steady dimensions must reuse at most two slots")
            let allocations=current.materialAllocationCount
            current.configure(player:player,edit:SessionEditState(style:.none,intensity:0,ballSkin:.original),track:track)
            XCTAssertEqual(current.retainedMaterialSlotCount,0)
            current.configure(player:player,edit:SessionEditState(style:.none,intensity:0,ballSkin:.chrome),track:track)
            try await Task.sleep(for:.milliseconds(200))
            current.stop();current.removeFromSuperview()
            XCTAssertEqual(current.retainedMaterialSlotCount,0)
            measurements.append(["cycle":cycle,"steady_allocations":allocations,"retained_after_stop":current.retainedMaterialSlotCount])
            }
            view=nil
            try await Task.sleep(for:.milliseconds(150))
            XCTAssertNil(releasedView,"Dismissed playback surface must be released")
        }
        let output=URL.documentsDirectory.appendingPathComponent("autonomous-material-lifecycle.json")
        try JSONSerialization.data(withJSONObject:measurements,options:.prettyPrinted).write(to:output)
    }

    func testStoppedSurfaceCanBeReleased() async throws {
        weak var weakView: EffectVideoView?
        autoreleasepool {
            let view=EffectVideoView();weakView=view
            view.stop()
        }
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertNil(weakView)
    }
}
