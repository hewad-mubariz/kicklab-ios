import Foundation
import CoreGraphics

/// Lab candidate. At most one added crop per frame, bounded by the last strong
/// direct anchor. A crop cannot keep itself alive indefinitely.
nonisolated final class ShortGapBallRecoveryPolicy {
    struct Observation { let time:Double; let ball:Detection }
    struct Request { let roi:CGRect; let predicted:CGPoint; let previous:Detection; let size:CGSize }
    var history = [Observation]()
    var strongTime:Double?
    var lastTime:Double?
    var size = CGSize.zero
    var consecutiveFailures = 0
    func reset() { history=[]; strongTime=nil; lastTime=nil; consecutiveFailures=0 }
    func request(time:Double, size:CGSize, direct:Detection?, baselineCalls:Int, sceneCut:Bool, kind:String) -> Request? {
        guard time.isFinite, size.width.isFinite, size.height.isFinite, min(size.width,size.height)>0 else { reset(); return nil }
        if sceneCut || size != self.size || lastTime.map({ time <= $0 || time-$0 > 0.1 }) == true { reset() }
        self.size=size; lastTime=time
        if let direct {
            guard [direct.score,direct.x,direct.y,direct.width,direct.height].allSatisfy(\.isFinite),
                direct.width>0, direct.height>0 else { reset(); return nil }
            if let previous=history.last, hypot((previous.ball.x-direct.x)*size.width,(previous.ball.y-direct.y)*size.height) > max(0.08*max(size.width,size.height),4*max(direct.width*size.width,direct.height*size.height)) { history=[]; strongTime=nil }
            history.append(Observation(time:time,ball:direct)); history=Array(history.suffix(4))
            if direct.score >= 0.5 && kind == "detector" { strongTime=time }
            consecutiveFailures=0
            return nil
        }
        guard baselineCalls == 1, history.count >= 2, let strongTime, time-strongTime <= 0.5,
            consecutiveFailures < 3, let last=history.last, time-last.time <= 0.12 else { return nil }
        let diameter=max(last.ball.width*size.width,last.ball.height*size.height)
        guard diameter/max(size.width,size.height) <= 0.035 else { return nil }
        let prior=history[history.count-2], dt=last.time-prior.time
        guard dt > 0, dt <= 0.1 else { return nil }
        let displacement=CGPoint(x:(last.ball.x-prior.ball.x)*size.width, y:(last.ball.y-prior.ball.y)*size.height)
        let factor=min(2,(time-last.time)/dt)
        let predicted=CGPoint(x:last.ball.x*size.width+displacement.x*factor,y:last.ball.y*size.height+displacement.y*factor)
        let edge=min(min(size.width,size.height),max(96,(max(size.width,size.height)*256/1920).rounded()))
        let roi=CGRect(x:max(0,min(size.width-edge,(predicted.x-edge/2).rounded())), y:max(0,min(size.height-edge,(predicted.y-edge/2).rounded())),width:edge,height:edge)
        return Request(roi:roi,predicted:predicted,previous:last.ball,size:size)
    }
    func accept(_ result:FrameDetections, request:Request, time:Double) -> Bool {
        guard let b=result.ball, let mask=result.ballMask,
              [b.score,b.x,b.y,b.width,b.height].allSatisfy(\.isFinite), b.score >= 0.6,
              b.width > 0, b.height > 0 else { consecutiveFailures += 1; return false }
        let fill=Double(mask.alpha.filter{$0>=128}.count)/Double(mask.width*mask.height)
        let w=request.size.width,h=request.size.height, d=max(request.previous.width*w,request.previous.height*h)
        let box=CGRect(x:(b.x-b.width/2)*w,y:(b.y-b.height/2)*h,width:b.width*w,height:b.height*h)
        let valid = fill >= 0.15 && fill <= 0.95
            && request.roi.insetBy(dx:2,dy:2).contains(box)
            && b.width/request.previous.width >= 0.5 && b.width/request.previous.width <= 1.8
            && b.height/request.previous.height >= 0.5 && b.height/request.previous.height <= 1.8
            && hypot(b.x*w-request.predicted.x,b.y*h-request.predicted.y) <= max(12*max(w,h)/1920,2*d)
        if valid { history.append(Observation(time:time,ball:b));history=Array(history.suffix(4));consecutiveFailures=0 }
        else { consecutiveFailures += 1 }
        return valid
    }
}
