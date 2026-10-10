import AVFoundation
import CoreImage
import Foundation
import Vision

/// Offline, appearance-only repair of up to three missing masks between two observations.
/// Both neighbours must agree after registration to the missing frame's pixels.
/// A ball entering or leaving through the frame edge is repaired too; its masks are
/// clipped by the frame, so its visible size may change faster than in mid-frame.
/// No endpoint extension, detector changes, counter input or recovered-to-recovered chaining.
nonisolated enum BallMaskGapRefiner {
    struct Request {
        let before: RecordedFrame
        let after: RecordedFrame
        let time: Double
        init(before: RecordedFrame, after: RecordedFrame, time: Double? = nil) {
            self.before = before; self.after = after; self.time = time ?? (before.time + after.time) / 2
        }
        var fraction: Double { (time - before.time) / max(after.time - before.time, 1e-9) }
    }
    static let maximumMissingFrames = 3
    struct Result {
        let mask: BallMask
        let agreement: Double
        let photometricError: Double
        let consistentFraction: Double
    }
    private static let dimension = 256

    static func requests(frames: [RecordedFrame], frameDuration: Double) -> [Request] {
        guard frameDuration.isFinite, frameDuration > 0, frameDuration <= 1.0/24 else { return [] }
        let recoveredTimes = frames.filter(\.isVisualRecovery).map(\.time)
        let original = frames.filter { $0.detected && !$0.isVisualMaskRepair && !$0.isVisualRecovery }
            .sorted { $0.time < $1.time }
        return zip(original, original.dropFirst()).flatMap { a, b -> [Request] in
            let gap=b.time-a.time
            let missing=Int((gap/frameDuration).rounded())-1
            guard usable(a.ballMask), usable(b.ballMask), a.time.isFinite, b.time.isFinite,
                  missing >= 1, missing <= maximumMissingFrames,
                  abs(gap-Double(missing+1)*frameDuration) < 0.0025*Double(missing+1),
                  a.score >= 0.4, b.score >= 0.4 else {return []}
            let values=[a.x,a.y,a.width,a.height,b.x,b.y,b.width,b.height]
            guard values.allSatisfy(\.isFinite),[a.width,a.height,b.width,b.height].min()! > 0 else {return []}
            func atEdge(_ f: RecordedFrame) -> Bool {
                f.x-f.width/2 <= 0.005 || f.y-f.height/2 <= 0.005 || f.x+f.width/2 >= 0.995 || f.y+f.height/2 >= 0.995
            }
            // A ball crossing the frame edge is clipped, so its box can grow quickly.
            let edge=atEdge(a) || atEdge(b)
            let ratios=[a.width/b.width,b.width/a.width,a.height/b.height,b.height/a.height]
            let dx=(b.x-a.x)/max(a.width,b.width),dy=(b.y-a.y)/max(a.height,b.height)
            guard ratios.max()! < (edge ? 2.4 : 1.65), hypot(dx,dy) < 0.6*Double(missing+1) else {return []}
            return (1...missing).map { k in Request(before:a,after:b,time:a.time+Double(k)*gap/Double(missing+1)) }
                .filter { request in !recoveredTimes.contains { abs($0-request.time) < 0.003 } }
        }
    }

    static func refine(source: URL, frames: [RecordedFrame],
                       onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [RecordedFrame] {
        try Task.checkCancellation()
        guard frames.contains(where: { $0.ballMask != nil }) else { return frames }
        let scoped=source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let asset=AVURLAsset(url:source)
        guard let video=try await asset.loadTracks(withMediaType:.video).first else { return frames }
        let duration=try await asset.load(.duration)
        let composition=try await EffectVideoGeometry.composition(track:video,duration:duration,shortEdge:720)
        // Bound optional work on very long or difficult recordings.
        let pending=Array(requests(frames:frames,frameDuration:CMTimeGetSeconds(composition.frameDuration)).prefix(240))
        guard !pending.isEmpty else { onProgress?(1); return frames }
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.videoComposition=composition;output.alwaysCopiesSampleData=false;reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure(1) }
        defer { if reader.status == .reading {reader.cancelReading()} }
        let context=CIContext(options:[.useSoftwareRenderer: VideoWorkExecution.cpuOnly,.workingColorSpace:NSNull(),.cacheIntermediates:false])
        var recent=[(Double,CVPixelBuffer)](),added=[RecordedFrame](),next=0
        func frame(at time: Double) -> CVPixelBuffer? { recent.first { abs($0.0-time) < 0.003 }?.1 }
        while next < pending.count {
            try await VideoWorkExecution.checkpoint(requiresGPU: true)
            guard let sample = output.copyNextSampleBuffer() else { break }
            try Task.checkCancellation()
            guard let pixels=CMSampleBufferGetImageBuffer(sample) else {continue}
            let time=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            recent.append((time,pixels));if recent.count>maximumMissingFrames+2 {recent.removeFirst()}
            while next<pending.count, time>pending[next].after.time+0.003 {next += 1}
            // Every missing frame of one gap shares the same after-observation.
            while next<pending.count, abs(time-pending[next].after.time)<0.003 {
                let request=pending[next]
                defer {next += 1;onProgress?(Double(next)/Double(pending.count))}
                guard let before=frame(at:request.before.time),let current=frame(at:request.time) else {continue}
                // Vision failures leave this frame untouched; cancellation still propagates.
                let recovered=try? autoreleasepool { try recover(before:before,current:current,
                    after:pixels,request:request,context:context) }
                try Task.checkCancellation()
                if let recovered {
                    let a=request.before,b=request.after,f=request.fraction,t=frameTime(request.time,recent)
                    func mix(_ u:Double,_ v:Double)->Double {u+(v-u)*f}
                    added.append(RecordedFrame(time:t,x:mix(a.x,b.x),y:mix(a.y,b.y),
                        width:mix(a.width,b.width),height:mix(a.height,b.height),score:min(a.score,b.score),
                        smoothedX:mix(a.smoothedX,b.smoothedX),smoothedY:mix(a.smoothedY,b.smoothedY),
                        vy:0,motion:.unknown,detected:true,person:nil,ballMask:recovered.mask,
                        usesBallMasks:true,isVisualMaskRepair:true))
                }
            }
        }
        if reader.status == .failed {throw reader.error ?? failure(2)}
        onProgress?(1)
        return added.isEmpty ? frames : (frames+added).sorted {$0.time<$1.time}
    }

    private static func frameTime(_ time: Double,_ recent: [(Double,CVPixelBuffer)]) -> Double {
        recent.first { abs($0.0-time) < 0.003 }?.0 ?? time
    }

    static func recover(before: CVPixelBuffer,current: CVPixelBuffer,after: CVPixelBuffer,
                        request: Request,context: CIContext) throws -> Result? {
        let w=CVPixelBufferGetWidth(current),h=CVPixelBufferGetHeight(current)
        guard w>0,h>0,CVPixelBufferGetWidth(before)==w,CVPixelBufferGetHeight(before)==h,
              CVPixelBufferGetWidth(after)==w,CVPixelBufferGetHeight(after)==h,
              let firstMask=request.before.ballMask,let lastMask=request.after.ballMask,
              usable(firstMask),usable(lastMask) else {return nil}
        let a=request.before,b=request.after
        let diameter=max(a.width*Double(w),a.height*Double(h),b.width*Double(w),b.height*Double(h))
        guard diameter>=12,diameter<Double(min(w,h))*0.4 else {return nil}
        let side=min(min(w,h),Int(ceil(diameter*2.3)))
        let f=request.fraction
        let x=max(0,min(w-side,Int(((a.x+(b.x-a.x)*f)*Double(w)-Double(side)/2).rounded())))
        let y=max(0,min(h-side,Int(((a.y+(b.y-a.y)*f)*Double(h)-Double(side)/2).rounded())))
        let region=CGRect(x:x,y:y,width:side,height:side)
        let patches=try [before,current,after].map { try patch($0,region:region,context:context) }
        let currentBytes=bytes(patches[1])
        var warped=[[Double]](),errors=[Double](),consistent=[Double]()
        for (index,mask) in [(0,firstMask),(2,lastMask)] {
            try Task.checkCancellation()
            let forward=try flow(from:patches[1],to:patches[index])
            let reverse=try flow(from:patches[index],to:patches[1])
            let anchorBytes=bytes(patches[index])
            var alpha=[Double](repeating:0,count:dimension*dimension),weight=0.0,error=0.0,valid=0.0
            for py in 0..<dimension {for px in 0..<dimension {
                let i=py*dimension+px,dx=Double(forward[i*2]),dy=Double(forward[i*2+1])
                let sx=Double(px)+dx,sy=Double(py)+dy
                guard sx>=0,sy>=0,sx<Double(dimension-1),sy<Double(dimension-1),dx.isFinite,dy.isFinite else {continue}
                let sourceX=(Double(x)+(sx+0.5)/Double(dimension)*Double(side))/Double(w)
                let sourceY=(Double(y)+(sy+0.5)/Double(dimension)*Double(side))/Double(h)
                let value=mask.coverage(x:sourceX,y:sourceY)
                guard value>0 else {continue}
                alpha[i]=value;weight += value
                let rx=sample(reverse,x:sx,y:sy,channels:2,channel:0)
                let ry=sample(reverse,x:sx,y:sy,channels:2,channel:1)
                if hypot(dx+rx,dy+ry)<3 {valid += value}
                for channel in 0..<3 {
                    error += value*abs(Double(currentBytes[i*4+channel])-sample(anchorBytes,x:sx,y:sy,channels:4,channel:channel))/3
                }
            }}
            guard weight>64 else {return nil}
            warped.append(alpha);errors.append(error/weight);consistent.append(valid/weight)
        }
        var intersection=0.0,union=0.0
        var alpha=[UInt8](repeating:0,count:dimension*dimension)
        for i in alpha.indices {
            let lo=min(warped[0][i],warped[1][i]),hi=max(warped[0][i],warped[1][i])
            intersection += lo;union += hi;alpha[i]=UInt8((lo*255).rounded())
        }
        let agreement=intersection/max(union,1)
        guard agreement>=0.60,errors.max()!<=14,consistent.min()!>=0.85,
              intersection>=128 else {return nil}
        // Keep one supported visible component, removing detached flow specks.
        // This only removes coverage; it never fills the hand/foot cutout.
        alpha=keepMainComponent(alpha)
        let occupied=alpha.indices.filter {alpha[$0]>=32}
        guard !occupied.isEmpty else {return nil}
        let left=max(0,occupied.map{$0%dimension}.min()!-2),right=min(dimension-1,occupied.map{$0%dimension}.max()!+2)
        let top=max(0,occupied.map{$0/dimension}.min()!-2),bottom=min(dimension-1,occupied.map{$0/dimension}.max()!+2)
        let mw=min(128,right-left+1),mh=min(128,bottom-top+1)
        var small=[UInt8](repeating:0,count:mw*mh)
        for yy in 0..<mh {for xx in 0..<mw {
            let sx=Double(left)+(Double(xx)+0.5)/Double(mw)*Double(right-left+1)-0.5
            let sy=Double(top)+(Double(yy)+0.5)/Double(mh)*Double(bottom-top+1)-0.5
            small[yy*mw+xx]=UInt8(max(0,min(255,sample(alpha,x:sx,y:sy,channels:1,channel:0))).rounded())
        }}
        let mask=BallMask(rect:CGRect(x:(Double(x)+Double(left)*Double(side)/Double(dimension))/Double(w),
            y:(Double(y)+Double(top)*Double(side)/Double(dimension))/Double(h),
            width:Double(right-left+1)*Double(side)/Double(dimension)/Double(w),
            height:Double(bottom-top+1)*Double(side)/Double(dimension)/Double(h)),width:mw,height:mh,alpha:small)
        return Result(mask:mask,agreement:agreement,photometricError:errors.max()!,consistentFraction:consistent.min()!)
    }

    private static func usable(_ mask:BallMask?)->Bool {
        guard let mask,(8...128).contains(mask.width),(8...128).contains(mask.height),
              mask.alpha.count==mask.width*mask.height,
              [mask.rect.minX,mask.rect.minY,mask.rect.width,mask.rect.height].allSatisfy(\.isFinite),
              mask.rect.width>0,mask.rect.height>0 else {return false}
        let fill=Double(mask.alpha.filter {$0>=128}.count)/Double(mask.alpha.count)
        // Almost solid rectangles do not establish a visible ball boundary;
        // transporting them can carry a hand or shirt into the missing frame.
        return fill>=0.12 && fill<=0.90
    }

    private static func patch(_ pixels: CVPixelBuffer,region: CGRect,context: CIContext) throws -> CVPixelBuffer {
        let rect=CGRect(x:region.minX,y:Double(CVPixelBufferGetHeight(pixels))-region.maxY,width:region.width,height:region.height)
        let image=CIImage(cvPixelBuffer:pixels).cropped(to:rect)
            .transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY))
            .samplingLinear().transformed(by:CGAffineTransform(scaleX:Double(dimension)/region.width,y:Double(dimension)/region.height))
        var result:CVPixelBuffer?
        guard CVPixelBufferCreate(nil,dimension,dimension,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&result)==kCVReturnSuccess,let result else {throw failure(3)}
        context.render(image,to:result);return result
    }
    private static func flow(from: CVPixelBuffer,to: CVPixelBuffer) throws -> [Float] {
        try autoreleasepool {
            let request=VNGenerateOpticalFlowRequest(targetedCVPixelBuffer:to,options:[:])
            request.revision=VNGenerateOpticalFlowRequestRevision1
            request.computationAccuracy = .high;request.outputPixelFormat=kCVPixelFormatType_TwoComponent32Float
            try VNImageRequestHandler(cvPixelBuffer:from,options:[:]).perform([request])
            guard let buffer=request.results?.first?.pixelBuffer,
                  CVPixelBufferGetWidth(buffer)==dimension,CVPixelBufferGetHeight(buffer)==dimension else {throw failure(4)}
            CVPixelBufferLockBaseAddress(buffer,.readOnly);defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
            let stride=CVPixelBufferGetBytesPerRow(buffer)/MemoryLayout<Float>.size
            guard let ptr=CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:Float.self) else {throw failure(5)}
            return (0..<dimension).flatMap {Array(UnsafeBufferPointer(start:ptr+$0*stride,count:dimension*2))}
        }
    }
    private static func bytes(_ pixels: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels,.readOnly);defer {CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
        let stride=CVPixelBufferGetBytesPerRow(pixels),ptr=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self)
        return (0..<dimension).flatMap {Array(UnsafeBufferPointer(start:ptr+$0*stride,count:dimension*4))}
    }
    private static func sample<T: BinaryFloatingPoint>(_ values:[T],x:Double,y:Double,channels:Int,channel:Int)->Double {
        interpolate(x:x,y:y) {xx,yy in Double(values[(yy*dimension+xx)*channels+channel])}
    }
    private static func sample(_ values:[UInt8],x:Double,y:Double,channels:Int,channel:Int)->Double {
        interpolate(x:x,y:y) {xx,yy in Double(values[(yy*dimension+xx)*channels+channel])}
    }
    private static func interpolate(x:Double,y:Double,value:(Int,Int)->Double)->Double {
        guard x.isFinite,y.isFinite,x>=0,y>=0,x<Double(dimension-1),y<Double(dimension-1) else {return 0}
        let ix=Int(x),iy=Int(y),fx=x-Double(ix),fy=y-Double(iy)
        return (value(ix,iy)*(1-fx)+value(ix+1,iy)*fx)*(1-fy)+(value(ix,iy+1)*(1-fx)+value(ix+1,iy+1)*fx)*fy
    }
    private static func keepMainComponent(_ alpha:[UInt8])->[UInt8] {
        var visited=[Bool](repeating:false,count:alpha.count),largest=[Int]()
        for seed in alpha.indices where alpha[seed]>=128 && !visited[seed] {
            var queue=[seed],next=0;visited[seed]=true
            while next<queue.count {
                let i=queue[next];next += 1;let x=i%dimension,y=i/dimension
                for yy in max(0,y-1)...min(dimension-1,y+1) {for xx in max(0,x-1)...min(dimension-1,x+1) {
                    let j=yy*dimension+xx
                    if !visited[j] && alpha[j]>=128 {visited[j]=true;queue.append(j)}
                }}
            }
            if queue.count>largest.count {largest=queue}
        }
        var keep=[Bool](repeating:false,count:alpha.count)
        for i in largest {let x=i%dimension,y=i/dimension
            for yy in max(0,y-2)...min(dimension-1,y+2) {for xx in max(0,x-2)...min(dimension-1,x+2) {keep[yy*dimension+xx]=true}}
        }
        return alpha.indices.map {keep[$0] ? alpha[$0]:0}
    }
    private static func failure(_ code:Int)->NSError {NSError(domain:"KickLab.MaskGap",code:code)}
}
