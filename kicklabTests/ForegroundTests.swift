import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import simd
import Testing
@testable import kicklab

struct ForegroundTests {
    @Test func closerStadiumFramingKeepsTheSoleOnTheGroundAndSupportsAFullTurn() {
        var rig=SceneCameraRig(aspect:9.0/16,subjectHeight:0.23,ground:SIMD2(0.52,0.70))
        rig.stadiumFraming=true;rig.movement=0
        let foot=rig.worldPoint(sourceUV:rig.ground)
        let framed=rig.project(foot,at:0)
        #expect(abs(foot.y)<0.00001)
        #expect(abs(framed.y-0.84)<0.001)
        let head=rig.project(rig.worldPoint(sourceUV:rig.ground-SIMD2(0,0.23)),at:0)
        #expect(framed.y-head.y>0.45 && framed.y-head.y<0.47)
        let front=rig.pose(at:0)
        rig.look.x=2*Float.pi
        #expect(simd_distance(rig.pose(at:0).forward,front.forward)<0.00001)
        rig.look.x = .pi
        #expect(simd_dot(rig.pose(at:0).forward,front.forward)<(-0.99))
    }

    @Test func measuredSourcePanPreservesSourceProjectionAndGroundContact() {
        var rig=SceneCameraRig(aspect:9.0/16,subjectHeight:0.4,ground:SIMD2(0.5,0.85))
        rig.movement=0;rig.recordedPan=SIMD2(0.08,0.045)
        rig.contact=VisibleFootContact(point:SIMD2(0.53,0.86),width:0.03)
        for uv:SIMD2<Float> in [SIMD2(0.3,0.4),SIMD2(0.6,0.8)] {
            #expect(simd_distance(rig.project(rig.worldPoint(sourceUV:uv),at:0),uv)<0.00001)
        }
        #expect(abs(rig.support.y)<0.00001)
        let prior=SIMD2<Float>(0.01,0.02)
        #expect(StadiumCameraMotion.integrate(prior,imageShift:SIMD2(0.5,0.5),aspect:rig.aspect,tanHalfFOV:rig.tanHalfFOV)==prior)
        #expect(StadiumCameraMotion.backgroundRegion(excluding:CGRect(x:0,y:0,width:1,height:1))==nil)
    }

    @Test func packedForegroundPreservesColorAndNumericMaskCoverage() throws {
        let color=try ForegroundMaskProcessor.buffer(width:8,height:4,format:kCVPixelFormatType_32BGRA)
        let mask=try ForegroundMaskProcessor.buffer(width:8,height:4,format:kCVPixelFormatType_32BGRA)
        let packed=try ForegroundMaskProcessor.buffer(width:16,height:4,format:kCVPixelFormatType_32BGRA)
        for (buffer,value) in [(color,UInt8(57)),(mask,UInt8(128))] {
            CVPixelBufferLockBaseAddress(buffer,[])
            memset(CVPixelBufferGetBaseAddress(buffer)!,Int32(value),CVPixelBufferGetBytesPerRow(buffer)*4)
            CVPixelBufferUnlockBaseAddress(buffer,[])
        }
        try StadiumPreviewPreparer.pack(color:color,mask:mask,into:packed)
        CVPixelBufferLockBaseAddress(packed,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(packed,.readOnly)}
        let p=CVPixelBufferGetBaseAddress(packed)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(packed)
        for y in 0..<4 {
            #expect(p[y*row]==57 && p[y*row+31]==57)
            #expect(p[y*row+32]==128 && p[y*row+63]==128)
        }
    }

    @Test func cachedCameraStateSeeksDeterministically() throws {
        let rig=SceneCameraRig(aspect:9.0/16,subjectHeight:0.4,ground:SIMD2(0.5,0.85))
        let recording=StadiumSceneRecording(camera:rig,frames:[
            .init(time:0,contact:nil,pan:.zero),
            .init(time:0.033,contact:VisibleFootContact(point:SIMD2(0.52,0.86),width:0.03),pan:SIMD2(0.01,0.02))],
            sourceRect:CGRect(x:0.2,y:0.3,width:0.5,height:0.4))
        let decoded=try JSONDecoder().decode(StadiumSceneRecording.self,from:JSONEncoder().encode(recording))
        #expect(decoded.sample(at:0.032).recordedPan==SIMD2(0.01,0.02))
        #expect(decoded.sample(at:0).recordedPan == .zero)
        #expect(decoded.sample(at:0.032).contact?.point==SIMD2(0.52,0.86))
        #expect(decoded.sourceRect==recording.sourceRect)
    }
    @Test func personGuideRejectsFurnitureAndSelectsTheHumanInstance() throws {
        let labels=try ForegroundMaskProcessor.buffer(width:80,height:80,format:kCVPixelFormatType_OneComponent8)
        let guide=try ForegroundMaskProcessor.buffer(width:40,height:40,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(labels,[]);CVPixelBufferLockBaseAddress(guide,[])
        let l=CVPixelBufferGetBaseAddress(labels)!.assumingMemoryBound(to:UInt8.self),lr=CVPixelBufferGetBytesPerRow(labels)
        let g=CVPixelBufferGetBaseAddress(guide)!.assumingMemoryBound(to:UInt8.self),gr=CVPixelBufferGetBytesPerRow(guide)
        for y in 0..<80 {for x in 0..<80 {l[y*lr+x]=x<45 ? 1:2}}
        for y in 0..<40 {for x in 0..<40 {g[y*gr+x]=0}}
        CVPixelBufferUnlockBaseAddress(guide,[]);CVPixelBufferUnlockBaseAddress(labels,[])
        #expect(DetailedForegroundMaskProcessor.personInstance(labels,guide:guide)==nil)
        #expect(!DetailedForegroundMaskProcessor.containsPerson(guide))
        CVPixelBufferLockBaseAddress(guide,[])
        for y in 5..<35 {for x in 26..<38 {g[y*gr+x]=255}}
        CVPixelBufferUnlockBaseAddress(guide,[])
        #expect(DetailedForegroundMaskProcessor.personInstance(labels,guide:guide)==2)
        #expect(DetailedForegroundMaskProcessor.containsPerson(guide))
    }
    private func ballFrame(center:SIMD2<Double>?,distractor:Bool=false,shaded:Bool=false) throws -> CVPixelBuffer {
        let frame=try ForegroundMaskProcessor.buffer(width:200,height:240,format:kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(frame,[]);defer {CVPixelBufferUnlockBaseAddress(frame,[])}
        let p=CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<240 {for x in 0..<200 {
            let onBall=center.map {hypot(Double(x)+0.5-$0.x,Double(y)+0.5-$0.y)<18} ?? false
            let greenCircle=distractor && hypot(Double(x)-140,Double(y)-135)<19
            let leaf=UInt8((x*13+y*17)%19)
            let i=y*row+x*4
            p[i]=onBall ? 210:25+leaf;p[i+1]=onBall ? 218:(greenCircle ? 165:80)+leaf
            p[i+2]=onBall ? 232:25+leaf;p[i+3]=255
            if shaded {
                p[i]=onBall ? 122:(greenCircle ? 140:90)+leaf/4
                p[i+1]=onBall ? 108:(greenCircle ? 210:98)+leaf/4
                p[i+2]=onBall ? 100:(greenCircle ? 170:85)+leaf/4
            }
        }}
        return frame
    }

    @Test func currentPixelsRecoverWeakDetectionsAndRejectBackgroundDrift() throws {
        let tracker=BallCutoutTracker()
        let first=try #require(try tracker.update(source:ballFrame(center:SIMD2(80,150)),
            hint:CGRect(x:60.0/200,y:130.0/240,width:40.0/200,height:40.0/240),confidence:0.12,at:0))
        #expect(abs(first.midX*200-80)<3 && abs(first.midY*240-150)<3)
        // High detector confidence cannot relocate the alpha onto green foliage.
        let next=try #require(try tracker.update(source:ballFrame(center:SIMD2(98,128),distractor:true),
            hint:CGRect(x:120.0/200,y:115.0/240,width:40.0/200,height:40.0/240),confidence:0.85,at:1.0/30))
        #expect(abs(next.midX*200-98)<3 && abs(next.midY*240-128)<3)
        let recovered=try #require(try tracker.update(source:ballFrame(center:SIMD2(112,114)),hint:nil,confidence:0,at:2.0/30))
        #expect(abs(recovered.midX*200-112)<3 && abs(recovered.midY*240-114)<3)
    }

    @Test func aMissingBallCannotProduceAPredictedCircleOfBackground() throws {
        let tracker=BallCutoutTracker()
        _=try tracker.update(source:ballFrame(center:SIMD2(80,150)),
            hint:CGRect(x:60.0/200,y:130.0/240,width:40.0/200,height:40.0/240),confidence:0.3,at:0)
        for i in 1...6 {
            let result=try tracker.update(source:ballFrame(center:nil,distractor:true),
                hint:CGRect(x:120.0/200,y:115.0/240,width:40.0/200,height:40.0/240),confidence:0.6,at:Double(i)/30)
            #expect(result==nil)
        }
    }

    @Test func shadedBallWinsOverBrightFoliageWithAStrongerEdge() throws {
        let tracker=BallCutoutTracker()
        _=try #require(try tracker.update(source:ballFrame(center:SIMD2(80,150),shaded:true),
            hint:CGRect(x:60.0/200,y:130.0/240,width:40.0/200,height:40.0/240),confidence:0.3,at:0))
        let next=try #require(try tracker.update(source:ballFrame(center:SIMD2(98,128),distractor:true,shaded:true),
            hint:CGRect(x:120.0/200,y:115.0/240,width:40.0/200,height:40.0/240),confidence:0.8,at:1.0/30))
        #expect(abs(next.midX*200-98)<4 && abs(next.midY*240-128)<4)
    }

    @Test func appearanceRankingPenaltyDoesNotEraseAValidShadedBall() throws {
        let tracker=BallCutoutTracker()
        _=try #require(try tracker.update(source:ballFrame(center:SIMD2(80,150)),
            hint:CGRect(x:60.0/200,y:130.0/240,width:40.0/200,height:40.0/240),confidence:0.3,at:0))
        let next=try #require(try tracker.update(source:ballFrame(center:SIMD2(98,128),shaded:true),
            hint:CGRect(x:78.0/200,y:108.0/240,width:40.0/200,height:40.0/240),confidence:0.08,at:1.0/30))
        #expect(abs(next.midX*200-98)<4 && abs(next.midY*240-128)<4)
    }

    @Test func personCoverageCheckDetectsALostFootWithoutExpandingHealthyEdges() throws {
        let mask=try ForegroundMaskProcessor.buffer(width:80,height:120,format:kCVPixelFormatType_OneComponent8)
        let guide=try ForegroundMaskProcessor.buffer(width:40,height:60,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(mask,[]);CVPixelBufferLockBaseAddress(guide,[])
        let p=CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(mask)
        let g=CVPixelBufferGetBaseAddress(guide)!.assumingMemoryBound(to:UInt8.self),gr=CVPixelBufferGetBytesPerRow(guide)
        for y in 0..<120 {for x in 0..<80 {p[y*row+x]=(20..<60).contains(x) && (10..<110).contains(y) ? 255:0}}
        for y in 0..<60 {for x in 0..<40 {g[y*gr+x]=(10..<30).contains(x) && (5..<55).contains(y) ? 255:0}}
        CVPixelBufferUnlockBaseAddress(mask,[]);CVPixelBufferUnlockBaseAddress(guide,[])
        #expect(!DetailedForegroundMaskProcessor.needsPersonRepair(mask,guide:guide))
        CVPixelBufferLockBaseAddress(mask,[])
        for y in 85..<110 {for x in 20..<60 {p[y*row+x]=0}}
        CVPixelBufferUnlockBaseAddress(mask,[])
        #expect(DetailedForegroundMaskProcessor.needsPersonRepair(mask,guide:guide))
        CVPixelBufferLockBaseAddress(guide,[]);memset(g,0,gr*60);CVPixelBufferUnlockBaseAddress(guide,[])
        #expect(!DetailedForegroundMaskProcessor.needsPersonRepair(mask,guide:guide))
    }
    @Test func offscreenBallHintsCannotCreateAnInvalidInstanceSearchRange() {
        #expect(DetailedForegroundMaskProcessor.visibleBallCrop(CGRect(x:-0.4,y:0.4,width:0.1,height:0.1))==nil)
        #expect(DetailedForegroundMaskProcessor.visibleBallCrop(CGRect(x:0.4,y:1.1,width:0.1,height:0.1))==nil)
        #expect(DetailedForegroundMaskProcessor.visibleBallCrop(.zero)==nil)
        let partial=DetailedForegroundMaskProcessor.visibleBallCrop(CGRect(x:-0.01,y:0.4,width:0.1,height:0.1))
        #expect(partial?.minX==0)
    }
    @Test func detachedBallFringeIsRemovedBeforeTheRefinedBallIsCombined() throws {
        let alpha=try ForegroundMaskProcessor.buffer(width:80,height:120,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(alpha,[])
        let p=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(alpha)
        for y in 0..<120 {for x in 0..<80 {
            let body=(20..<40).contains(x) && (10..<110).contains(y)
            let fringe=x==19 && (10..<110).contains(y)
            let ball=hypot(Double(x-61),Double(y-70))<12
            p[y*row+x]=body || ball ? 255:fringe ? 20:0
        }}
        CVPixelBufferUnlockBaseAddress(alpha,[])
        let result=try DetailedForegroundMaskProcessor.bodyComponent(alpha)
        CVPixelBufferLockBaseAddress(result,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(result,.readOnly)}
        let b=CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(result)
        #expect(b[70*stride+61]==0)
        #expect(b[70*stride+50]==0)
        #expect(b[70*stride+30]==255)
        #expect(b[70*stride+19]==20) // preserve genuine soft body-edge coverage
    }

    @Test func floatMasksKeepCoverageWithoutGammaConversion() throws {
        let alpha=try ForegroundMaskProcessor.buffer(width:4,height:2,format:kCVPixelFormatType_OneComponent32Float)
        CVPixelBufferLockBaseAddress(alpha,[])
        let p=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:Float.self)
        p[0]=0;p[1]=0.5;p[2]=1;p[3] = .nan
        CVPixelBufferUnlockBaseAddress(alpha,[])
        let output=try DetailedForegroundMaskProcessor.alpha8(alpha)
        CVPixelBufferLockBaseAddress(output,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(output,.readOnly)}
        let b=CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to:UInt8.self)
        #expect(b[0]==0 && b[1]==128 && b[2]==255 && b[3]==0)
    }

    @Test func contactUsesTheBottomOfASoftVisibleSole() throws {
        let alpha=try ForegroundMaskProcessor.buffer(width:80,height:120,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(alpha,[])
        let p=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(alpha)
        for y in 0..<120 {for x in 0..<80 {
            let core=(30..<45).contains(x) && (10..<100).contains(y)
            let sole=(30..<45).contains(x) && (100..<104).contains(y)
            p[y*row+x]=core ? 255:sole ? 110:0
        }}
        CVPixelBufferUnlockBaseAddress(alpha,[])
        let contact=try #require(VisibleFootContact.measure(person:alpha,rect:CGRect(x:0,y:0,width:1,height:1)))
        #expect(abs(contact.point.y-104.0/120)<0.0001)
        var rig=SceneCameraRig(aspect:2.0/3,subjectHeight:0.7,ground:SIMD2(0.5,0.86))
        rig.contact=contact
        #expect(rig.worldPoint(sourceUV:SIMD2(contact.point.x,103.5/120)).y>0)
    }
    @Test func cameraStartsAtSourceFramingAndMovesSmoothly() {
        let rig = SceneCameraRig(aspect: 9.0/16, subjectHeight: 0.3, ground: SIMD2(0.55,0.72))
        for uv: SIMD2<Float> in [SIMD2(0,0),SIMD2(1,1),SIMD2(0.38,0.65),rig.ground] {
            #expect(simd_distance(rig.project(rig.worldPoint(sourceUV: uv),at: 0),uv) < 0.00001)
        }
        #expect(abs(rig.worldPoint(sourceUV: rig.ground).y) < 0.00001)
        let source = rig.worldPoint(sourceUV: SIMD2(0.4,0.4))
        let start = rig.project(source,at: 0), first = rig.project(source,at: 1.0/60)
        let moved = rig.project(source,at: 5)
        #expect(simd_distance(start,first) < 0.00001) // no start-of-clip kick
        #expect(simd_distance(start,moved) > 0.001)
        #expect(simd_distance(start,moved) < 0.08) // restrained enough for a 2D body
        #expect(rig.project(source,at: 5) == moved) // seeking has no integrated state
        var locked = rig; locked.movement = 0
        #expect(simd_distance(locked.project(source,at: 8),start) < 0.00001)
    }

    @Test func cameraGivesDepthParallaxWithoutDetachingTheGroundAnchor() {
        let rig = SceneCameraRig(aspect: 9.0/16, subjectHeight: 0.5, ground: SIMD2(0.5,0.85))
        let foot = rig.worldPoint(sourceUV:rig.ground)
        let floor = SIMD3<Float>(rig.anchorX,0,0)
        for t in [0.0,1,3,7] {
            #expect(simd_distance(rig.project(foot,at:t),rig.project(floor,at:t)) < 0.00001)
        }
        let far = SIMD3<Float>(foot.x,0,-19)
        let nearMotion = rig.project(foot,at:7)-rig.project(foot,at:0)
        let farMotion = rig.project(far,at:7)-rig.project(far,at:0)
        #expect(simd_distance(nearMotion,farMotion) > 0.001)
    }

    @Test func localBallMaskFindsTheVisibleEdgeAndClearsOutsideIt() throws {
        let source = try ForegroundMaskProcessor.buffer(width:160,height:200,format:kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(source,[])
        let bytes = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to:UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(source)
        for y in 0..<200 {for x in 0..<160 {
            let ball = hypot(Double(x)+0.5-65,Double(y)+0.5-130)<20
            let p=bytes+y*row+x*4
            p[0]=ball ? 220:25;p[1]=ball ? 225:100;p[2]=ball ? 230:20;p[3]=255
        }}
        CVPixelBufferUnlockBaseAddress(source,[])
        let patch = try #require(try BallForegroundMask.make(source:source,bounds:CGRect(x:43.0/160,y:108.0/200,width:44.0/160,height:44.0/200)))
        CVPixelBufferLockBaseAddress(patch.pixels,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(patch.pixels,.readOnly)}
        let mask = CVPixelBufferGetBaseAddress(patch.pixels)!.assumingMemoryBound(to:UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(patch.pixels)
        func alpha(_ x:Int,_ y:Int)->UInt8 {
            let px=x-Int((patch.rect.minX*160).rounded()),py=y-Int((patch.rect.minY*200).rounded())
            return mask[py*stride+px]
        }
        #expect(alpha(65,130)==255)
        #expect(alpha(83,130)>200)
        #expect(alpha(88,130)==0) // the original grass outside the refined edge
        #expect(alpha(65,107)==0)
        #expect(try BallForegroundMask.make(source:source,bounds:.zero)==nil)
    }

    @Test func visibleContactChangesPlayerDepthWithoutMovingTheSceneCamera() {
        let base = SceneCameraRig(aspect: 9.0/16, subjectHeight: 0.5, ground: SIMD2(0.5,0.88))
        for uv: SIMD2<Float> in [SIMD2(0.3,0.79),SIMD2(0.6,0.94)] {
            var rig = base
            rig.contact = VisibleFootContact(point:uv,width:0.04)
            #expect(abs(rig.support.y) < 0.00001)
            #expect(simd_distance(rig.project(rig.support,at:0),uv) < 0.00001)
            for time in [0.0,2,6] {
                #expect(rig.pose(at:time).eye == base.pose(at:time).eye)
                let floor = SIMD3<Float>(rig.support.x,0,rig.support.z)
                #expect(simd_distance(rig.project(rig.support,at:time),rig.project(floor,at:time)) < 0.00001)
            }
            let head = SIMD2<Float>(0.4,0.3)
            #expect(simd_distance(rig.project(rig.worldPoint(sourceUV:head),at:0),head) < 0.00001)
        }
    }

    @Test func visibleContactIgnoresRaisedLegAndDetachedMaskComponents() throws {
        let mask = try ForegroundMaskProcessor.buffer(width:100,height:140,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(mask,[])
        let bytes = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to:UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(mask)
        for y in 0..<140 { for x in 0..<100 {
            let torso = (30..<70).contains(x) && (10..<70).contains(y)
            let standing = (35..<44).contains(x) && (60..<125).contains(y)
            let raised = (61..<69).contains(x) && (60..<104).contains(y)
            let ball = (78..<90).contains(x) && (115..<130).contains(y)
            bytes[y*row+x] = torso || standing || raised || ball ? 255 : 0
        }}
        CVPixelBufferUnlockBaseAddress(mask,[])
        let rect = CGRect(x:0.1,y:0.2,width:0.8,height:0.7)
        let foot = try #require(VisibleFootContact.measure(person:mask,rect:rect))
        #expect(abs(foot.point.x - 0.416) < 0.01)
        #expect(abs(foot.point.y - 0.8225) < 0.005)
        // All-background masks must not invent a contact point.
        CVPixelBufferLockBaseAddress(mask,[])
        for y in 0..<140 {for x in 0..<100 {bytes[y*row+x] = 0}}
        CVPixelBufferUnlockBaseAddress(mask,[])
        #expect(VisibleFootContact.measure(person:mask,rect:rect) == nil)
    }

    @Test func lostFootCannotMoveTheGroundToTheKnee() throws {
        var tracker = FootContactTracker()
        let foot = VisibleFootContact(point:SIMD2(0.2,0.88),width:0.05)
        _ = tracker.update(foot,at:0)
        let knee = VisibleFootContact(point:SIMD2(0.2,0.59),width:0.04)
        for i in 1...8 {
            let candidate = tracker.update(knee,at:Double(i)/30)
            let held = try #require(candidate)
            #expect(held.point == foot.point)
            #expect(held.confidence < 1)
        }
        let missingCandidate = tracker.update(nil,at:0.3)
        let missing = try #require(missingCandidate)
        #expect(missing.point == foot.point)
        let recoveredCandidate = tracker.update(foot,at:1.0/3)
        let recovered = try #require(recoveredCandidate)
        #expect(recovered.confidence == 1)
        // A new sequence / seek clears the old support estimate.
        let resetCandidate = tracker.update(knee,at:2)
        let reset = try #require(resetCandidate)
        #expect(reset.point == knee.point)
    }

    @Test func acceptedDownwardContactDoesNotLagAboveTheVisibleFoot() throws {
        var tracker=FootContactTracker()
        _=tracker.update(VisibleFootContact(point:SIMD2(0.5,0.85),width:0.04),at:0)
        let observed=VisibleFootContact(point:SIMD2(0.5,0.86),width:0.04)
        let next=tracker.update(observed,at:1.0/60)
        let accepted=try #require(next)
        var rig=SceneCameraRig(aspect:9.0/16,subjectHeight:0.4,ground:SIMD2(0.5,0.85));rig.contact=accepted
        #expect(abs(rig.worldPoint(sourceUV:observed.point).y)<0.00001)
        let rising=tracker.update(VisibleFootContact(point:SIMD2(0.5,0.855),width:0.04),at:2.0/60)
        let higher=try #require(rising)
        #expect(higher.point.y>0.855 && higher.point.y<0.86)
    }
}
