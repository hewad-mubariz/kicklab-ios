import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Relocalize on current pixels; detector confidence only proposes a search.
nonisolated enum BallImageLocator {
    struct Appearance {var color,chroma:SIMD3<Double>}
    struct Match {let bounds:CGRect;let appearance:Appearance;let quality,support:Double}
    private static let directions=(0..<40).map {i in
        let a=Double(i)/40 * .pi*2;return SIMD2(cos(a),sin(a))
    }
    static func locate(_ source:CVPixelBuffer,proposals:[CGRect],appearance:Appearance?,expectedRadius:Double?)->Match? {
        let w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source)==kCVPixelFormatType_32BGRA else {return nil}
        let boxes=proposals.filter {$0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width>0 && $0.height>0}
        guard !boxes.isEmpty else {return nil}
        CVPixelBufferLockBaseAddress(source,.readOnly);defer{CVPixelBufferUnlockBaseAddress(source,.readOnly)}
        guard let p=CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to:UInt8.self) else {return nil}
        let row=CVPixelBufferGetBytesPerRow(source)
        func color(_ x:Double,_ y:Double)->SIMD3<Double> {
            let xx=max(0,min(w-1,Int(x.rounded()))),yy=max(0,min(h-1,Int(y.rounded()))),a=p+yy*row+xx*4
            return SIMD3(Double(a[2]),Double(a[1]),Double(a[0]))
        }
        func describe(_ x:Double,_ y:Double,_ r:Double)->Appearance {
            var sum=color(x,y),n=1.0
            for ring in [0.35,0.70] {for d in directions {sum+=color(x+d.x*r*ring,y+d.y*r*ring);n+=1}}
            let mean=sum/n;return Appearance(color:mean,chroma:mean/max(20,mean.x+mean.y+mean.z))
        }
        struct Candidate {let x,y,r,score,support:Double;let feature:Appearance}
        func evaluate(_ x:Double,_ y:Double,_ r:Double,_ anchor:SIMD2<Double>)->Candidate? {
            guard r>=4,r<Double(min(w,h))*0.18,x-r>=0,y-r>=0,x+r<Double(w),y+r<Double(h) else {return nil}
            let shell=max(1.5,r*0.075)
            var delta=SIMD3<Double>.zero,edge=0.0,supported=0.0
            for d in directions {
                let diff=color(x+d.x*(r-shell),y+d.y*(r-shell))-color(x+d.x*(r+shell),y+d.y*(r+shell))
                delta+=simd_clamp(diff,SIMD3(repeating:-100),SIMD3(repeating:100))
                let magnitude=simd_length(diff)/sqrt(3);edge+=min(80,magnitude)
                if magnitude>15 {supported+=1}
            }
            delta/=Double(directions.count);edge/=Double(directions.count);supported/=Double(directions.count)
            let boundary=simd_length(delta)/sqrt(3)+edge*0.28
            guard boundary>=10,supported>=0.45 else {return nil}
            let feature=describe(x,y,r)
            let colorDistance=appearance.map {simd_distance(feature.chroma,$0.chroma)} ?? 0
            // Bright leaves can have a stronger edge than a shaded football.
            // Reject incompatible candidates before ranking, so a distractor
            // cannot suppress a valid runner-up elsewhere in the search.
            guard colorDistance<=0.10 else {return nil}
            let penalty=appearance.map {a in colorDistance*420+min(55,simd_distance(feature.color,a.color)/sqrt(3))*0.25} ?? 0
            let distance=simd_distance(SIMD2(x,y),anchor)/r
            let sizePenalty=expectedRadius.map {abs(log(r/$0))*16} ?? 0
            let score=boundary-penalty-distance*1.2-sizePenalty
            return Candidate(x:x,y:y,r:r,score:score,support:supported,feature:feature)
        }
        var best:Candidate?
        for box in boxes {
            let anchor=SIMD2(Double(box.midX)*Double(w),Double(box.midY)*Double(h))
            let raw=min(Double(box.width)*Double(w),Double(box.height)*Double(h))/2
            guard raw>=4,raw<Double(min(w,h))*0.18 else {continue}
            let radius=expectedRadius.map {min(raw*1.35,max(raw*0.7,$0))} ?? raw
            let step=max(1.5,radius*0.25),reach=radius*1.65
            for scale in [0.78,0.9,1.0,1.1,1.22] {
                for x in stride(from:anchor.x-reach,through:anchor.x+reach,by:step) {
                    for y in stride(from:anchor.y-reach,through:anchor.y+reach,by:step) {
                        if let c=evaluate(x,y,radius*scale,anchor),c.score>(best?.score ?? -.infinity) {best=c}
                    }
                }
            }
        }
        guard let coarse=best else {return nil}
        let anchor=SIMD2(coarse.x,coarse.y)
        for dr in [-0.045,0.0,0.045] {for dx in [-0.12,-0.06,0,0.06,0.12] {for dy in [-0.12,-0.06,0,0.06,0.12] {
            if let c=evaluate(coarse.x+dx*coarse.r,coarse.y+dy*coarse.r,coarse.r*(1+dr),anchor),c.score>best!.score {best=c}
        }}}
        // Acceptance is based on actual boundary and appearance support above.
        // Ranking penalties must not erase an otherwise valid blurred ball.
        guard let b=best else {return nil}
        return Match(bounds:CGRect(x:(b.x-b.r)/Double(w),y:(b.y-b.r)/Double(h),width:b.r*2/Double(w),height:b.r*2/Double(h)),appearance:b.feature,quality:b.score,support:b.support)
    }
}
