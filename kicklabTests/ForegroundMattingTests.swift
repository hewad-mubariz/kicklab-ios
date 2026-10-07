import CoreImage
import CoreVideo
import Metal
import Testing
@testable import kicklab

struct ForegroundMattingTests {
    private func buffer(_ w:Int,_ h:Int,_ format:OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        try ForegroundMaskProcessor.buffer(width:w,height:h,format:format)
    }
    private func value(_ b:CVPixelBuffer,_ x:Int,_ y:Int,_ channel:Int=0)->UInt8 {
        CVPixelBufferLockBaseAddress(b,.readOnly);defer {CVPixelBufferUnlockBaseAddress(b,.readOnly)}
        return CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self)[y*CVPixelBufferGetBytesPerRow(b)+x*4+channel]
    }
    private func rectangle(offset:Int=0,fringe:Bool=false) throws -> (CVPixelBuffer,CVPixelBuffer) {
        let color=try buffer(128,128),mask=try buffer(128,128)
        for (b,isMask) in [(color,false),(mask,true)] {
            CVPixelBufferLockBaseAddress(b,[])
            let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(b)
            for y in 0..<128 {for x in 0..<128 {
                let inside=(32+offset..<80+offset).contains(x) && (24..<104).contains(y)
                let coverage=(32+offset-(fringe ? 3:0)..<80+offset+(fringe ? 3:0)).contains(x) && (24..<104).contains(y)
                let i=y*row+x*4
                p[i]=isMask ? (coverage ? 255:0):(inside ? 30:20)
                p[i+1]=isMask ? p[i]:(inside ? 45:170)
                p[i+2]=isMask ? p[i]:(inside ? 190:20)
                p[i+3]=255
            }}
            CVPixelBufferUnlockBaseAddress(b,[])
        }
        return (color,mask)
    }
    @Test func locallyMissingHandIsRepairedEvenWhenWholeBodyCoveragePasses() throws {
        let alpha=try buffer(120,160,kCVPixelFormatType_OneComponent8),guide=try buffer(120,160,kCVPixelFormatType_OneComponent8)
        for (b,includeHand) in [(alpha,false),(guide,true)] {
            CVPixelBufferLockBaseAddress(b,[])
            let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(b)
            for y in 0..<160 {for x in 0..<120 {
                let body=(35..<80).contains(x) && (12..<150).contains(y)
                let hand=includeHand && (80..<90).contains(x) && (65..<78).contains(y)
                p[y*row+x]=body || hand ? 255:0
            }}
            CVPixelBufferUnlockBaseAddress(b,[])
        }
        #expect(!DetailedForegroundMaskProcessor.needsPersonRepair(alpha,guide:guide))
        let regions=DetailedForegroundMaskProcessor.personRepairRegions(alpha,guide:guide)
        #expect(regions.count==1)
        #expect(regions.first?.contains(CGPoint(x:85.0/120,y:70.0/160))==true)
        #expect(regions.first?.contains(CGPoint(x:50.0/120,y:140.0/160))==false)
        #expect(DetailedForegroundMaskProcessor.personRepairRegions(guide,guide:guide).isEmpty)
    }
    @Test func sourceColorRemovesAnOpaqueBackgroundFringeWithoutErodingTheInterior() throws {
        let device=try #require(MTLCreateSystemDefaultDevice()),ci=CIContext(mtlDevice:device)
        let processor=try ForegroundEdgeProcessor(device:device,context:ci)
        let (color,mask)=try rectangle(fringe:true)
        let result=try processor.process(color:color,mask:mask,at:0)
        #expect(value(result.alpha,30,64)<90) // old green background was incorrectly opaque
        #expect(value(result.alpha,45,64)>250)
        #expect(abs(Int(value(result.color,45,64,2))-190)<2)
        #expect(value(result.alpha,15,64)==0)
        #expect(value(result.color,15,64,1)==0) // no original park stored outside coverage
    }
    @Test func motionAlignedHistoryReducesAFluctuationAndDoesNotLeaveAGhost() throws {
        let device=try #require(MTLCreateSystemDefaultDevice()),ci=CIContext(mtlDevice:device)
        let processor=try ForegroundEdgeProcessor(device:device,context:ci)
        let (first,firstMask)=try rectangle()
        _=try processor.process(color:first,mask:firstMask,at:0)
        let (next,nextMask)=try rectangle(offset:8)
        // A spurious current-frame translucent patch inside the moved object.
        CVPixelBufferLockBaseAddress(nextMask,[])
        let p=CVPixelBufferGetBaseAddress(nextMask)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(nextMask)
        for y in 52..<76 {for x in 55..<70 {for c in 0..<3 {p[y*row+x*4+c]=210}}}
        CVPixelBufferUnlockBaseAddress(nextMask,[])
        let flow=try buffer(128,128,kCVPixelFormatType_TwoComponent32Float)
        CVPixelBufferLockBaseAddress(flow,[])
        let f=CVPixelBufferGetBaseAddress(flow)!.assumingMemoryBound(to:Float.self),fr=CVPixelBufferGetBytesPerRow(flow)/4
        for y in 0..<128 {for x in 0..<128 {f[y*fr+x*2] = -8;f[y*fr+x*2+1]=0}}
        CVPixelBufferUnlockBaseAddress(flow,[])
        let result=try processor.process(color:next,mask:nextMask,at:1.0/30,backwardFlow:flow)
        #expect(processor.usedHistory)
        #expect(value(result.alpha,61,64)>225)
        #expect(value(result.alpha,34,64)==0) // old object location, now background
        let reset=try processor.process(color:next,mask:nextMask,at:0)
        #expect(!processor.usedHistory)
        #expect(value(reset.alpha,61,64)==210)
    }

    @Test func premultipliedCacheCompositesSoftCoverageExactlyOnce() throws {
        let device=try #require(MTLCreateSystemDefaultDevice()),ci=CIContext(mtlDevice:device)
        let processor=try ForegroundEdgeProcessor(device:device,context:ci)
        let (color,mask)=try rectangle()
        CVPixelBufferLockBaseAddress(mask,[])
        let p=CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(mask)
        for y in 45..<85 {for x in 45..<70 {for c in 0..<3 {p[y*row+x*4+c]=128}}}
        CVPixelBufferUnlockBaseAddress(mask,[])
        let refined=try processor.process(color:color,mask:mask,at:0)
        let packed=try buffer(256,128),target=try buffer(128,128)
        try StadiumPreviewPreparer.pack(color:refined.color,mask:refined.alpha,into:packed)
        let renderer=try StadiumPreviewRenderer()
        let camera=SceneCameraRig(aspect:1,subjectHeight:0.4,ground:SIMD2(0.5,0.85))
        try renderer.render(source:packed,mask:packed,output:target,camera:camera,time:0,scene:false,packed:true,refined:true)
        func linear(_ s:Double)->Double {s<=0.04045 ? s/12.92:pow((s+0.055)/1.055,2.4)}
        func display(_ l:Double)->Double {l<=0.0031308 ? l*12.92:1.055*pow(l,1/2.4)-0.055}
        let alpha=128.0/255
        // At source pixel (61,64), the checkerboard's even cell is (.22,.19,.30).
        let expected=display(linear(190.0/255)*alpha+linear(0.22)*(1-alpha))*255
        #expect(abs(Double(value(target,61,64,2))-expected)<3)
        // The lossless layout must use the separate matte, even if the video's
        // alpha half contains unrelated values. Reprojection is shared.
        CVPixelBufferLockBaseAddress(packed,[])
        let packedBytes=CVPixelBufferGetBaseAddress(packed)!.assumingMemoryBound(to:UInt8.self),packedRow=CVPixelBufferGetBytesPerRow(packed)
        for y in 0..<128 {for x in 128..<256 {for c in 0..<3 {packedBytes[y*packedRow+x*4+c]=255}}}
        CVPixelBufferUnlockBaseAddress(packed,[])
        let separate=try buffer(128,128)
        try renderer.render(source:packed,mask:refined.alpha,output:separate,camera:camera,time:0,scene:false,packed:true,refined:true,separateAlpha:true)
        #expect(value(separate,61,64,2)==value(target,61,64,2))
        #expect(value(separate,15,64,2)==value(target,15,64,2))
    }

    @Test func faintHistoryCannotRegrowOutsideTheCurrentSilhouette() throws {
        let device=try #require(MTLCreateSystemDefaultDevice()),ci=CIContext(mtlDevice:device)
        let processor=try ForegroundEdgeProcessor(device:device,context:ci)
        let (color,oldMask)=try rectangle()
        CVPixelBufferLockBaseAddress(oldMask,[])
        let p=CVPixelBufferGetBaseAddress(oldMask)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(oldMask)
        for y in 0..<128 {for x in 0..<128 {for c in 0..<3 {if p[y*row+x*4+c]>0 {p[y*row+x*4+c]=40}}}}
        CVPixelBufferUnlockBaseAddress(oldMask,[])
        let first=try processor.process(color:color,mask:oldMask,at:0)
        #expect(value(first.alpha,61,64)==40)
        let empty=try buffer(128,128),flow=try buffer(128,128,kCVPixelFormatType_TwoComponent32Float)
        for b in [empty,flow] {
            CVPixelBufferLockBaseAddress(b,[])
            memset(CVPixelBufferGetBaseAddress(b)!,0,CVPixelBufferGetBytesPerRow(b)*CVPixelBufferGetHeight(b))
            CVPixelBufferUnlockBaseAddress(b,[])
        }
        // Identical colors and perfect flow isolate the low-alpha-history case:
        // photometric and alpha agreement alone must not authorize coverage.
        let result=try processor.process(color:color,mask:empty,at:1.0/30,backwardFlow:flow)
        #expect(processor.usedHistory)
        #expect(value(result.alpha,61,64)==0)
        #expect(value(result.color,61,64,2)==0)
    }

    @Test func trimapMakesDisagreementUnknownWithoutFillingRealGaps() throws {
        let w=96,h=96
        var a=[UInt8](repeating:0,count:w*h),g=a
        for y in 12..<84 {for x in 12..<84 {a[y*w+x]=255;g[y*w+x]=255}}
        // A missing hand/skin patch supported only by the person guide.
        for y in 24..<32 {for x in 24..<32 {a[y*w+x]=0}}
        // A broad genuine gap between limbs, not foreground to be filled.
        for y in 40..<64 {for x in 40..<64 {a[y*w+x]=0;g[y*w+x]=0}}
        // Background incorrectly attached to the opaque silhouette.
        for y in 68..<78 {for x in 68..<78 {g[y*w+x]=0}}
        let t=try PersonMatteRefiner.trimap(alpha:a,guide:g,width:w,height:h,radius:3)
        #expect(t[20*w+60]==255)
        #expect(t[28*w+28]==128)
        #expect(t[73*w+73]==128)
        #expect(t[52*w+52]==0)
        #expect(t[0]==0)
        #expect(Set(t).isSubset(of:[0,128,255]))
    }

    @Test func thinAgreedLimbsKeepAnInteriorWithoutProtectingGuideOnlyRepairs() throws {
        let w=96,h=96
        var original=[UInt8](repeating:0,count:w*h),guide=original
        for y in 12..<84 {for x in 44..<54 {original[y*w+x]=255;guide[y*w+x]=255}}
        // A second narrow region was added by guide-only repair.
        for y in 12..<84 {for x in 68..<78 {guide[y*w+x]=255}}
        let repaired=guide
        let constraints=try PersonMatteRefiner.constraints(alpha:repaired,guide:guide,width:w,height:h,radius:15,original:original)
        let t=constraints.trimap
        #expect(constraints.agreement[48*w+49]==255)
        #expect(constraints.agreement[48*w+73]==0)
        #expect(t[48*w+49]==128)
        #expect(t[48*w+73]==128)
        #expect(t[48*w+43]==128) // leave the fine edge to the learned model
        #expect(t[48*w+30]==0)
    }

    @Test func uncertainCroppedPlayerSupportRemainsEligible() throws {
        let w=160,h=160,a=[UInt8](repeating:0,count:w*h)
        var g=a
        for y in 20..<120 {for x in 152..<160 {g[y*w+x]=190}}
        let t=try PersonMatteRefiner.trimap(alpha:a,guide:g,width:w,height:h,radius:24)
        #expect(t[60*w+155]==128)
        #expect(t[60*w+100]==0)
    }

    @Test func selectedGuideExcludesDetachedFurnitureBeforeBuildingTheTrimap() throws {
        let w=96,h=96
        let pixels=try buffer(w,h,kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(pixels,[])
        let p=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(pixels)
        memset(p,0,row*h)
        var a=[UInt8](repeating:0,count:w*h)
        for y in 10..<85 {for x in 30..<55 {a[y*w+x]=255;p[y*row+x]=255}}
        for y in 60..<85 {for x in 70..<92 {p[y*row+x]=210}}
        CVPixelBufferUnlockBaseAddress(pixels,[])
        let selected=try DetailedForegroundMaskProcessor.bodyComponent(pixels)
        CVPixelBufferLockBaseAddress(selected,.readOnly)
        let g=CVPixelBufferGetBaseAddress(selected)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(selected)
        var guide=a
        for y in 0..<h {for x in 0..<w {guide[y*w+x]=g[y*stride+x]}}
        CVPixelBufferUnlockBaseAddress(selected,.readOnly)
        let t=try PersonMatteRefiner.trimap(alpha:a,guide:guide,width:w,height:h,radius:12)
        #expect(t[72*w+80]==0)
        #expect(t[40*w+42]==255)
    }

    @Test func faintSceneWideVeilLacksIdentityButPartialOpaquePeopleRemainEligible() throws {
        let mask=try buffer(128,128,kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(mask,[])
        let p=CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(mask)
        memset(p,110,row*128)
        CVPixelBufferUnlockBaseAddress(mask,[])
        #expect(!DetailedForegroundMaskProcessor.hasConfidentSupport(mask))
        let empty=try DetailedForegroundMaskProcessor.supportedMatte(mask)
        CVPixelBufferLockBaseAddress(empty,.readOnly)
        let cleared=CVPixelBufferGetBaseAddress(empty)!.assumingMemoryBound(to:UInt8.self)
        #expect(cleared[64*CVPixelBufferGetBytesPerRow(empty)+64]==0)
        CVPixelBufferUnlockBaseAddress(empty,.readOnly)
        CVPixelBufferLockBaseAddress(mask,[])
        memset(p,0,row*128)
        for y in 60..<64 {for x in 0..<3 {p[y*row+x]=255}}
        CVPixelBufferUnlockBaseAddress(mask,[])
        #expect(!DetailedForegroundMaskProcessor.containsPerson(mask))
        #expect(DetailedForegroundMaskProcessor.hasConfidentSupport(mask))
        #expect(try DetailedForegroundMaskProcessor.supportedMatte(mask) === mask)
    }
}
