import Foundation
import CoreGraphics

/// Visual-only current-pixel recovery. Full-frame inference still runs every
/// sample. A wider contextual crop must renew identity during a long small-ball
/// run; predictions alone never produce an observation or renew that checkpoint.
nonisolated final class DistantBallRecoveryPolicy {
    struct Observation { let time:Double; let ball:Detection }
    struct Request {
        let roi:CGRect; let predicted:CGPoint; let previous:Detection; let size:CGSize
        let time:Double; let context:Bool; let gap:Double
        var conservative:ShortGapBallRecoveryPolicy.Request? = nil
    }
    // Keep the qualified short-gap path independent. Broader search only spends
    // a call on frames where that path would have stopped searching.
    private let conservative = ShortGapBallRecoveryPolicy()
    private(set) var history = [Observation]()
    private(set) var checkpoint:Double?
    private(set) var lastTime:Double?
    private(set) var size = CGSize.zero
    private(set) var consecutiveFailures = 0
    private(set) var rejection = "none"
    private var pendingTime:Double?

    func reset() {
        history=[]; checkpoint=nil; lastTime=nil; consecutiveFailures=0; pendingTime=nil
        conservative.reset()
    }

    func request(time:Double, size:CGSize, direct:Detection?, baselineCalls:Int, sceneCut:Bool, kind:String) -> Request? {
        pendingTime=nil
        guard time.isFinite, size.width.isFinite, size.height.isFinite, min(size.width,size.height)>0 else { reset(); return nil }
        if sceneCut || size != self.size || lastTime.map({ time <= $0 || time-$0 > 0.1 }) == true { reset() }
        self.size=size; lastTime=time
        let preferred=conservative.request(time:time,size:size,direct:direct,baselineCalls:baselineCalls,sceneCut:sceneCut,kind:kind)
        if let direct {
            guard Self.finite(direct) else { reset(); return nil }
            if let previous=history.last,
                time-previous.time > 0.2 || hypot((previous.ball.x-direct.x)*size.width,(previous.ball.y-direct.y)*size.height) > max(0.08*max(size.width,size.height),4*max(direct.width*size.width,direct.height*size.height)) {
                history=[]; checkpoint=nil
            }
            remember(direct,time:time)
            if direct.score >= 0.5 && kind == "detector" { checkpoint=time }
            consecutiveFailures=0
            return nil
        }
        if let preferred {
            pendingTime=time
            return Request(roi:preferred.roi,predicted:preferred.predicted,previous:preferred.previous,size:preferred.size,
                           time:time,context:false,gap:time-(history.last?.time ?? time),conservative:preferred)
        }
        guard baselineCalls == 1, history.count >= 2, let checkpoint,
              time-checkpoint <= 0.6, consecutiveFailures < 8,
              let last=history.last, time-last.time <= 0.2 else { return nil }
        let long=max(size.width,size.height)
        let diameter=max(last.ball.width*size.width,last.ball.height*size.height)
        guard diameter/long <= 0.035 else { return nil }
        let prior=history[history.count-2], dt=last.time-prior.time
        guard dt > 0, dt <= 0.2 else { return nil }
        let gap=time-last.time
        // Do not extrapolate an old velocity indefinitely after an impact.
        let factor=min(gap,0.12)/dt
        let predicted=CGPoint(x:last.ball.x*size.width+(last.ball.x-prior.ball.x)*size.width*factor,
                              y:last.ball.y*size.height+(last.ball.y-prior.ball.y)*size.height*factor)
        let context=time-checkpoint >= 0.3 || consecutiveFailures > 0
        let base=max(96,(long*256/1920).rounded())
        let edge=min(min(size.width,size.height),base*(context ? 1.75 : 1))
        guard predicted.x >= -edge/4, predicted.x <= size.width+edge/4,
              predicted.y >= -edge/4, predicted.y <= size.height+edge/4 else { return nil }
        let roi=CGRect(x:max(0,min(size.width-edge,(predicted.x-edge/2).rounded())),
                       y:max(0,min(size.height-edge,(predicted.y-edge/2).rounded())),width:edge,height:edge)
        pendingTime=time
        return Request(roi:roi,predicted:predicted,previous:last.ball,size:size,time:time,context:context,gap:gap)
    }

    func accept(_ result:FrameDetections, request:Request, time:Double) -> Bool {
        guard pendingTime == time, time == request.time else { rejection="stale-request"; return false }
        pendingTime=nil
        func reject(_ reason:String)->Bool { rejection=reason; consecutiveFailures += 1; return false }
        if let preferred=request.conservative {
            guard conservative.accept(result,request:preferred,time:time), let ball=result.ball else { return reject("short-gap-rejected") }
            remember(ball,time:time); consecutiveFailures=0; rejection="accepted"
            return true
        }
        guard let b=result.ball, Self.finite(b), b.score >= (request.context ? 0.7 : 0.6) else { return reject("confidence") }
        guard let mask=result.ballMask, mask.width>0, mask.height>0,
              mask.alpha.count == mask.width*mask.height else { return reject("mask") }
        let fill=Double(mask.alpha.filter{$0>=128}.count)/Double(mask.width*mask.height)
        guard fill >= 0.15, fill <= 0.95 else { return reject("mask-fill") }
        let w=request.size.width,h=request.size.height,d=max(request.previous.width*w,request.previous.height*h)
        let box=CGRect(x:(b.x-b.width/2)*w,y:(b.y-b.height/2)*h,width:b.width*w,height:b.height*h)
        guard request.roi.insetBy(dx:2,dy:2).contains(box) else { return reject("crop-edge") }
        guard b.width/request.previous.width >= 0.5, b.width/request.previous.width <= 1.8,
              b.height/request.previous.height >= 0.5, b.height/request.previous.height <= 1.8 else { return reject("size") }
        // Modest uncertainty after a miss; never accept a jump anywhere in the
        // expanded crop just because the model is confident.
        let allowance=max(12*max(w,h)/1920,2*d) + min(0.02*max(w,h),max(0,request.gap-0.02)*0.15*max(w,h))
        guard hypot(b.x*w-request.predicted.x,b.y*h-request.predicted.y) <= allowance else { return reject("displacement") }
        remember(b,time:time)
        if request.context { checkpoint=time }
        consecutiveFailures=0; rejection="accepted"
        return true
    }

    private func remember(_ ball:Detection,time:Double) {
        history.append(Observation(time:time,ball:ball)); history=Array(history.suffix(4))
    }
    private static func finite(_ ball:Detection)->Bool {
        [ball.score,ball.x,ball.y,ball.width,ball.height].allSatisfy(\.isFinite) && ball.width>0 && ball.height>0
    }
}
