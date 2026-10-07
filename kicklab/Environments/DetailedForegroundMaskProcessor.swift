import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Offline, source-resolution subject lifting. The person and fast moving ball
/// have independent semantic masks, joined only after detached person-mask
/// components are removed. No previous-frame alpha is blended into moving feet.
nonisolated final class DetailedForegroundMaskProcessor {
    private let context: CIContext
    private let personCrop: CGRect
    private let refiner: PersonMatteRefiner?
    private let personRequest = VNGenerateForegroundInstanceMaskRequest()
    private let personGuide = VNGeneratePersonSegmentationRequest()
    private let ballRequest = VNGenerateForegroundInstanceMaskRequest()
    private let ballTracker = BallCutoutTracker()
    private(set) var lastBallBounds: CGRect?
    private(set) var lastBallMethod = "missing"
    private(set) var lastPersonRepairCount = 0
    var lastBallQuality:Double {lastBallBounds == nil ? 0:ballTracker.quality}

    init(sourceCrop: CGRect, context: CIContext, refiner: PersonMatteRefiner? = nil) {
        self.personCrop = sourceCrop; self.context = context; self.refiner = refiner
        personGuide.qualityLevel = .accurate
        personGuide.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func process(_ source: CVPixelBuffer, at time: Double, ball: CGRect?, ballConfidence: Double = 1,
                 trace: ((String, CVPixelBuffer, CGRect) throws -> Void)? = nil) throws -> ForegroundMatte {
        guard time.isFinite, CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            throw ForegroundMaskProcessor.Failure.invalidFrame
        }
        let (input, rect) = try crop(source, to:personCrop)
        let handler = VNImageRequestHandler(cvPixelBuffer:input,orientation:.up)
        try handler.perform([personGuide,personRequest])
        guard let guide=personGuide.results?.first?.pixelBuffer else {throw ForegroundMaskProcessor.Failure.missingMask}
        let alpha: CVPixelBuffer
        if let observation=personRequest.results?.first,
           let instance=Self.personInstance(observation.instanceMask,guide:guide) {
            let lifted=try observation.generateScaledMaskForImage(forInstances:IndexSet(integer:instance),from:handler)
            alpha=try Self.alpha8(lifted)
        } else {
            // Subject lift can return no instance when the person is entering
            // or leaving the frame. Person segmentation still returns a matte
            // (including an empty one); do not fail the entire video for this.
            alpha=try Self.alpha8(guide)
        }
        let cleaned = try Self.bodyComponent(alpha)
        let bodyGuide = try Self.bodyComponent(guide)
        let repaired = try repairPerson(cleaned,guide:bodyGuide)
        let estimate: CVPixelBuffer
        if let refiner,Self.containsPerson(repaired) {
            estimate = try refiner.process(source:input,alpha:repaired,guide:bodyGuide,original:cleaned)
        } else {estimate = repaired}
        let person=try Self.supportedMatte(estimate)
        try trace?("person-source",input,rect)
        try trace?("person-raw",alpha,rect)
        try trace?("person-guide",guide,rect)
        try trace?("person-cleaned",cleaned,rect)
        try trace?("person-repaired",repaired,rect)
        try trace?("person-refined",person,rect)
        var detail: BallForegroundMask.Patch?
        lastBallBounds=nil;lastBallMethod="missing"
        // This is a juggling foreground: an unaccompanied round furnishing or
        // toy in an empty room must not initialize the ball cutout.
        if Self.containsPerson(person),
           let ball = try ballTracker.update(source:source,hint:ball,confidence:ballConfidence,at:time) {
            lastBallBounds=ball
            detail = try ballMask(source,bounds:ball)
            if detail != nil {lastBallMethod="instance"}
            // Small balls may not be recognised by subject lift. A contour is
            // eligible only after current-image validation, never prediction alone.
            // A weak appearance match can still be confirmed by subject lift,
            // but it cannot authorize copying a geometric circle of pixels.
            if detail == nil, ballTracker.quality>=10 {
                detail = try BallForegroundMask.make(source:source,bounds:ball,refineBounds:false)
                if detail != nil {lastBallMethod="verified-contour"}
            }
        }
        if let detail { try trace?("ball",detail.pixels,detail.rect) }
        return ForegroundMatte(time:time,person:person,personRect:rect,ball:detail?.pixels,ballRect:detail?.rect)
    }

    /// A subject-lift instance can survive while a lower leg disappears. Check
    /// it against the independent, accurate person guide before accepting it.
    /// Repair uses this frame's pixels; an old foot is never pasted in place.
    private func repairPerson(_ alpha:CVPixelBuffer,guide:CVPixelBuffer) throws -> CVPixelBuffer {
        let regions = Self.personRepairRegions(alpha, guide: guide)
        lastPersonRepairCount = regions.count
        guard !regions.isEmpty else {return alpha}
        let size=CGSize(width:CVPixelBufferGetWidth(alpha),height:CVPixelBufferGetHeight(alpha))
        let original=CIImage(cvPixelBuffer:alpha,options:[.colorSpace:NSNull()])
        let guideImage=CIImage(cvPixelBuffer:guide,options:[.colorSpace:NSNull()])
        let scaled=guideImage.transformed(by:CGAffineTransform(scaleX:size.width/guideImage.extent.width,y:size.height/guideImage.extent.height))
        // Keep the trusted interior; do not replace the detailed existing edge
        // with a softer upscaled guide throughout the whole image.
        let confident=scaled.applyingFilter("CIColorMatrix",parameters:[
            "inputRVector":CIVector(x:2,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:2,z:0,w:0),
            "inputBVector":CIVector(x:0,y:0,z:2,w:0),"inputBiasVector":CIVector(x:-0.6,y:-0.6,z:-0.6,w:0)])
            .applyingFilter("CIColorClamp")
        var repaired = original
        for region in regions {
            let roi = CGRect(x:region.minX*size.width,y:(1-region.maxY)*size.height,
                width:region.width*size.width,height:region.height*size.height).integral
            repaired = repaired.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:confident.cropped(to:roi)])
        }
        let output=try ForegroundMaskProcessor.buffer(width:Int(size.width),height:Int(size.height),format:kCVPixelFormatType_OneComponent8)
        context.render(repaired,to:output,bounds:CGRect(origin:.zero,size:size),colorSpace:nil)
        return output
    }

    /// Find locally missing parts, even when a hand or raised foot is too small
    /// to affect whole-body coverage. Thin disagreements along a healthy edge
    /// do not authorize expanding the rest of the silhouette.
    static func personRepairRegions(_ alpha: CVPixelBuffer, guide: CVPixelBuffer) -> [CGRect] {
        guard [alpha,guide].allSatisfy({ CVPixelBufferGetPixelFormatType($0) == kCVPixelFormatType_OneComponent8 }) else { return [] }
        CVPixelBufferLockBaseAddress(alpha,.readOnly); CVPixelBufferLockBaseAddress(guide,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(guide,.readOnly); CVPixelBufferUnlockBaseAddress(alpha,.readOnly) }
        let w=CVPixelBufferGetWidth(guide),h=CVPixelBufferGetHeight(guide),row=CVPixelBufferGetBytesPerRow(guide)
        let aw=CVPixelBufferGetWidth(alpha),ah=CVPixelBufferGetHeight(alpha),ar=CVPixelBufferGetBytesPerRow(alpha)
        let g=CVPixelBufferGetBaseAddress(guide)!.assumingMemoryBound(to:UInt8.self),a=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self)
        var missing=[Bool](repeating:false,count:w*h),regions:[CGRect]=[]
        for y in 0..<h {for x in 0..<w {
            missing[y*w+x] = g[y*row+x]>235 && a[min(ah-1,y*ah/h)*ar+min(aw-1,x*aw/w)]<96
        }}
        for seed in missing.indices where missing[seed] {
            var queue=[seed],head=0,minX=seed%w,maxX=minX,minY=seed/w,maxY=minY
            missing[seed]=false
            while head<queue.count {
                let i=queue[head];head+=1;let x=i%w,y=i/w
                minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx>=0 && nx<w && ny>=0 && ny<h {
                    if missing[ny*w+nx] {missing[ny*w+nx]=false;queue.append(ny*w+nx)}
                }
            }
            guard queue.count>=max(6,w*h/15000),maxX-minX>=2,maxY-minY>=2 else {continue}
            let pad=4
            let x0=max(0,minX-pad),y0=max(0,minY-pad),x1=min(w,maxX+pad+1),y1=min(h,maxY+pad+1)
            regions.append(CGRect(x:Double(x0)/Double(w),y:Double(y0)/Double(h),width:Double(x1-x0)/Double(w),height:Double(y1-y0)/Double(h)))
        }
        return regions
    }

    static func needsPersonRepair(_ alpha:CVPixelBuffer,guide:CVPixelBuffer)->Bool {
        guard [alpha,guide].allSatisfy({CVPixelBufferGetPixelFormatType($0)==kCVPixelFormatType_OneComponent8}) else {return false}
        CVPixelBufferLockBaseAddress(alpha,.readOnly);CVPixelBufferLockBaseAddress(guide,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(alpha,.readOnly);CVPixelBufferUnlockBaseAddress(guide,.readOnly)}
        let w=CVPixelBufferGetWidth(alpha),h=CVPixelBufferGetHeight(alpha),row=CVPixelBufferGetBytesPerRow(alpha)
        let gw=CVPixelBufferGetWidth(guide),gh=CVPixelBufferGetHeight(guide),gr=CVPixelBufferGetBytesPerRow(guide)
        let p=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self),g=CVPixelBufferGetBaseAddress(guide)!.assumingMemoryBound(to:UInt8.self)
        var top=gh,bottom=0
        for y in 0..<gh {for x in 0..<gw where g[y*gr+x]>200 {top=min(top,y);bottom=max(bottom,y)}}
        guard bottom>top else {return false}
        let legs=top+(bottom-top)*2/3
        var total=0,covered=0,lower=0,lowerCovered=0
        for y in 0..<gh {for x in 0..<gw where g[y*gr+x]>200 {
            let hit=p[min(h-1,y*h/gh)*row+min(w-1,x*w/gw)]>64
            total+=1;if hit {covered+=1}
            if y>=legs {lower+=1;if hit {lowerCovered+=1}}
        }}
        return (total>16 && Double(covered)/Double(total)<0.85) || (lower>16 && Double(lowerCovered)/Double(lower)<0.80)
    }

    static func containsPerson(_ guide:CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(guide)==kCVPixelFormatType_OneComponent8 else {return false}
        CVPixelBufferLockBaseAddress(guide,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(guide,.readOnly)}
        let w=CVPixelBufferGetWidth(guide),h=CVPixelBufferGetHeight(guide),row=CVPixelBufferGetBytesPerRow(guide)
        let bytes=CVPixelBufferGetBaseAddress(guide)!.assumingMemoryBound(to:UInt8.self)
        var count=0
        for y in 0..<h {for x in 0..<w where bytes[y*row+x]>=128 {
            count+=1;if count>=max(16,w*h/2000) {return true}
        }}
        return false
    }

    static func hasConfidentSupport(_ alpha:CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(alpha)==kCVPixelFormatType_OneComponent8 else {return false}
        CVPixelBufferLockBaseAddress(alpha,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(alpha,.readOnly)}
        let w=CVPixelBufferGetWidth(alpha),h=CVPixelBufferGetHeight(alpha),row=CVPixelBufferGetBytesPerRow(alpha)
        let p=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self)
        var count=0
        for y in 0..<h {for x in 0..<w where p[y*row+x]>=200 {
            count+=1;if count>=max(8,w*h/100000) {return true}
        }}
        return false
    }

    /// Check the final estimate: a misleading guide can contain a confident
    /// wall/window while the learned refiner correctly finds no opaque person.
    /// Preserve small opaque fragments at the frame boundary; reject an all-
    /// uncertain veil with no reliable subject evidence anywhere in the matte.
    static func supportedMatte(_ alpha:CVPixelBuffer) throws -> CVPixelBuffer {
        guard !hasConfidentSupport(alpha) else {return alpha}
        let empty=try ForegroundMaskProcessor.buffer(width:CVPixelBufferGetWidth(alpha),height:CVPixelBufferGetHeight(alpha),format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(empty,[])
        memset(CVPixelBufferGetBaseAddress(empty)!,0,CVPixelBufferGetBytesPerRow(empty)*CVPixelBufferGetHeight(empty))
        CVPixelBufferUnlockBaseAddress(empty,[])
        return empty
    }

    /// Subject lifting also segments furniture. Use the person model only for
    /// identity; keep subject lifting's finer alpha once a person is identified.
    static func personInstance(_ labels:CVPixelBuffer,guide:CVPixelBuffer) -> Int? {
        guard CVPixelBufferGetPixelFormatType(labels)==kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetPixelFormatType(guide)==kCVPixelFormatType_OneComponent8 else {return nil}
        CVPixelBufferLockBaseAddress(labels,.readOnly);CVPixelBufferLockBaseAddress(guide,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(guide,.readOnly);CVPixelBufferUnlockBaseAddress(labels,.readOnly)}
        let w=CVPixelBufferGetWidth(labels),h=CVPixelBufferGetHeight(labels),row=CVPixelBufferGetBytesPerRow(labels)
        let gw=CVPixelBufferGetWidth(guide),gh=CVPixelBufferGetHeight(guide),gr=CVPixelBufferGetBytesPerRow(guide)
        let p=CVPixelBufferGetBaseAddress(labels)!.assumingMemoryBound(to:UInt8.self)
        let g=CVPixelBufferGetBaseAddress(guide)!.assumingMemoryBound(to:UInt8.self)
        var areas=[Int](repeating:0,count:256),hits=areas
        for y in 0..<h {for x in 0..<w {
            let id=Int(p[y*row+x]);guard id>0 else {continue}
            areas[id]+=1
            if g[min(gh-1,y*gh/h)*gr+min(gw-1,x*gw/w)]>=128 {hits[id]+=1}
        }}
        return (1..<256).filter {hits[$0]>=max(16,w*h/2000) && Double(hits[$0])/Double(max(1,areas[$0]))>0.2}
            .max {hits[$0]<hits[$1]}
    }

    private func crop(_ source:CVPixelBuffer,to rect:CGRect) throws -> (CVPixelBuffer,CGRect) {
        let w=CGFloat(CVPixelBufferGetWidth(source)),h=CGFloat(CVPixelBufferGetHeight(source))
        let pixels=CGRect(x:rect.minX*w,y:rect.minY*h,width:rect.width*w,height:rect.height*h)
            .integral.intersection(CGRect(x:0,y:0,width:w,height:h))
        guard !pixels.isNull, pixels.width>=2, pixels.height>=2 else { throw ForegroundMaskProcessor.Failure.invalidFrame }
        let result=try ForegroundMaskProcessor.buffer(width:Int(pixels.width),height:Int(pixels.height),format:kCVPixelFormatType_32BGRA)
        let ciRect=CGRect(x:pixels.minX,y:h-pixels.maxY,width:pixels.width,height:pixels.height)
        let image=CIImage(cvPixelBuffer:source).cropped(to:ciRect)
            .transformed(by:CGAffineTransform(translationX:-ciRect.minX,y:-ciRect.minY))
        context.render(image,to:result)
        return (result,CGRect(x:pixels.minX/w,y:pixels.minY/h,width:pixels.width/w,height:pixels.height/h))
    }

    private static func primaryInstance(_ labels:CVPixelBuffer,near point:CGPoint? = nil) -> Int? {
        guard CVPixelBufferGetPixelFormatType(labels)==kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(labels,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels,.readOnly) }
        let w=CVPixelBufferGetWidth(labels),h=CVPixelBufferGetHeight(labels),row=CVPixelBufferGetBytesPerRow(labels)
        guard let bytes=CVPixelBufferGetBaseAddress(labels)?.assumingMemoryBound(to:UInt8.self) else { return nil }
        var votes=[Double](repeating:0,count:256)
        if let point {
            guard point.x.isFinite,point.y.isFinite,point.x>=0,point.x<1,point.y>=0,point.y<1 else { return nil }
            // The detector supplies identity; a nearby hand must not win by area.
            let cx=Int(point.x*CGFloat(w)),cy=Int(point.y*CGFloat(h)),r=max(2,min(w,h)/22)
            for y in max(0,cy-r)..<min(h,cy+r+1) { for x in max(0,cx-r)..<min(w,cx+r+1) {
                votes[Int(bytes[y*row+x])]+=1
            }}
        } else {
            for y in 0..<h { for x in 0..<w {
                let dx=Double(x)/Double(w)-0.5,dy=Double(y)/Double(h)-0.45
                votes[Int(bytes[y*row+x])]+=exp(-(dx*dx*5+dy*dy*2))
            }}
        }
        votes[0]=0
        guard let best=votes.indices.max(by:{votes[$0]<votes[$1]}), votes[best]>0 else { return nil }
        return best
    }

    private func ballMask(_ source:CVPixelBuffer,bounds:CGRect) throws -> BallForegroundMask.Patch? {
        guard let padded=Self.visibleBallCrop(bounds) else { return nil }
        let (input,rect)=try crop(source,to:padded)
        let center=CGPoint(x:(bounds.midX-rect.minX)/rect.width,y:(bounds.midY-rect.minY)/rect.height)
        let handler=VNImageRequestHandler(cvPixelBuffer:input,orientation:.up)
        try handler.perform([ballRequest])
        guard let observation=ballRequest.results?.first,
              let instance=Self.primaryInstance(observation.instanceMask,near:center) else { return nil }
        let lifted=try observation.generateScaledMaskForImage(forInstances:IndexSet(integer:instance),from:handler)
        let alpha=try Self.alpha8(lifted)
        CVPixelBufferLockBaseAddress(alpha,[])
        defer { CVPixelBufferUnlockBaseAddress(alpha,[]) }
        let w=CVPixelBufferGetWidth(alpha),h=CVPixelBufferGetHeight(alpha),row=CVPixelBufferGetBytesPerRow(alpha)
        let bytes=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self)
        var core=0.0,coreCount=0
        for y in 0..<h { for x in 0..<w {
            let u=rect.minX+(CGFloat(x)+0.5)/CGFloat(w)*rect.width
            let v=rect.minY+(CGFloat(y)+0.5)/CGFloat(h)*rect.height
            let dx=(u-bounds.midX)/(bounds.width*0.5),dy=(v-bounds.midY)/(bounds.height*0.5)
            let radius=hypot(dx,dy)
            if radius<0.55 { core+=Double(bytes[y*row+x])/255;coreCount+=1 }
            // A tight image-verified support limits included hands/background.
            // The semantic boundary inside it remains untouched, including blur.
            let limit=max(0,min(1,(1.08-radius)/0.08))
            bytes[y*row+x]=UInt8((Double(bytes[y*row+x])*limit).rounded())
        }}
        guard coreCount>0,core/Double(coreCount)>0.45 else { return nil }
        return BallForegroundMask.Patch(pixels:alpha,rect:rect)
    }

    static func visibleBallCrop(_ bounds:CGRect) -> CGRect? {
        guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>0,bounds.height>0,
              bounds.midX.isFinite,bounds.midY.isFinite,
              bounds.midX>=0,bounds.midX<1,bounds.midY>=0,bounds.midY<1 else { return nil }
        // Keep the ball dominant in the subject-lifting input. A much wider
        // crop lets a nearby torso win and Vision may omit the football.
        return bounds.insetBy(dx:-bounds.width*0.4,dy:-bounds.height*0.4)
            .intersection(CGRect(x:0,y:0,width:1,height:1))
    }

    /// Masks are numeric coverage, not grayscale photographs. Preserve alpha
    /// without a color-space/gamma conversion when normalising Vision formats.
    static func alpha8(_ source:CVPixelBuffer) throws -> CVPixelBuffer {
        let w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source)
        let output=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(source,.readOnly);CVPixelBufferLockBaseAddress(output,[])
        defer {CVPixelBufferUnlockBaseAddress(output,[]);CVPixelBufferUnlockBaseAddress(source,.readOnly)}
        let src=CVPixelBufferGetBaseAddress(source)!,dst=CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to:UInt8.self)
        let sr=CVPixelBufferGetBytesPerRow(source),dr=CVPixelBufferGetBytesPerRow(output)
        switch CVPixelBufferGetPixelFormatType(source) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h { memcpy(dst+y*dr,src+y*sr,w) }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row=(src+y*sr).assumingMemoryBound(to:Float.self)
                for x in 0..<w {dst[y*dr+x]=UInt8((max(0,min(1,row[x].isFinite ? row[x]:0))*255).rounded())}
            }
        default: throw ForegroundMaskProcessor.Failure.missingMask
        }
        return output
    }

    /// Remove detached components before adding the separately refined ball.
    /// Otherwise max(person, ball) can preserve the person's coarse ball halo.
    static func bodyComponent(_ alpha:CVPixelBuffer) throws -> CVPixelBuffer {
        let w=CVPixelBufferGetWidth(alpha),h=CVPixelBufferGetHeight(alpha)
        let output=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(alpha,.readOnly);CVPixelBufferLockBaseAddress(output,[])
        defer {CVPixelBufferUnlockBaseAddress(output,[]);CVPixelBufferUnlockBaseAddress(alpha,.readOnly)}
        let src=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self),sr=CVPixelBufferGetBytesPerRow(alpha)
        let dst=CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to:UInt8.self),dr=CVPixelBufferGetBytesPerRow(output)
        var seen=[Bool](repeating:false,count:w*h),best=[Int]()
        for y in 0..<h {for x in 0..<w where src[y*sr+x]>=32 && !seen[y*w+x] {
            var queue=[y*w+x],head=0;seen[y*w+x]=true
            while head<queue.count {
                let i=queue[head];head+=1;let xx=i%w,yy=i/w
                for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx=xx+dx,ny=yy+dy
                    if nx>=0,nx<w,ny>=0,ny<h,!seen[ny*w+nx],src[ny*sr+nx]>=32 {
                        seen[ny*w+nx]=true;queue.append(ny*w+nx)
                    }
                }}
            }
            if queue.count>best.count {best=queue}
        }}
        for y in 0..<h {memset(dst+y*dr,0,w)}
        // Retain the soft one-pixel boundary surrounding the selected component.
        for i in best {
            let x=i%w,y=i/w
            for dy in -1...1 {for dx in -1...1 {
                let xx=x+dx,yy=y+dy
                if xx>=0,xx<w,yy>=0,yy<h {dst[yy*dr+xx]=src[yy*sr+xx]}
            }}
        }
        return output
    }
}
