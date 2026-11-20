#if DEBUG
import Foundation
import simd

/// Result confirmation never owns or rewinds the live animation clock.
/// Only the explicit, fully covered replay transition may seek backwards.
nonisolated struct PhysicalShotPlayback {
    enum Phase: String { case finish, emotion, transition, replay, returning, complete }
    struct State {
        let phase: Phase
        let time: Double
        let curtain: Double
        let showReady: Bool
    }
    static let replaySpeed=0.25
    let replayEnabled: Bool
    let confirmedAt,contact,contactInClip,duration,displayLead: Double
    let finishDuration: Double
    var emotionDuration: Double { 1.7 }
    var replayBegins: Double { finishDuration+emotionDuration+0.35 }
    var returnBegins: Double { replayBegins+0.2+duration/Self.replaySpeed }

    init(confirmedAt: Double,contact: Double,contactInClip: Double,duration: Double,
         liveMotionEnds: Double,displayLead: Double,replayEnabled: Bool=true) {
        self.confirmedAt=confirmedAt;self.contact=contact;self.contactInClip=contactInClip
        self.duration=duration;self.displayLead=displayLead
        self.replayEnabled=replayEnabled
        finishDuration=max(0.65,liveMotionEnds-confirmedAt)
    }
    func state(at now: Double) -> State {
        let age=max(0,now-confirmedAt)
        if age<finishDuration {
            // Continue the ball at the current shot time, never from contact again.
            return State(phase:.finish,time:min(duration,contactInClip+now-contact+displayLead),curtain:0,showReady:false)
        }
        if !replayEnabled { return State(phase:.complete,time:duration,curtain:0,showReady:true) }
        if age<finishDuration+emotionDuration {
            return State(phase:.emotion,time:age-finishDuration,curtain:0,showReady:false)
        }
        if age<replayBegins {
            return State(phase:.transition,time:duration,
                         curtain:Double(smooth(Float((age-finishDuration-emotionDuration)/0.25))),showReady:false)
        }
        if age<returnBegins {
            let t=age-replayBegins
            return State(phase:.replay,time:clamp((t-0.2)*Self.replaySpeed,0,duration),
                         curtain:1-Double(smooth(Float(t/0.2))),showReady:false)
        }
        if age<returnBegins+0.4 {
            let t=age-returnBegins
            return State(phase:.returning,time:duration,
                         curtain:Double(smooth(Float(t<0.2 ? t/0.2:(0.4-t)/0.2))),showReady:t>=0.2)
        }
        return State(phase:.complete,time:duration,curtain:0,showReady:true)
    }
}

/// Bounded samples of poses submitted to the renderer, including entry blending
/// and aim refinements. Times use the same output-lead clock as live poses.
nonisolated struct PhysicalPoseHistory {
    struct Sample {
        let time: Double
        let pose: [BonePose]
        let offset: SIMD3<Float>
    }
    private(set) var samples=[Sample]()
    mutating func append(time: Double,pose: [BonePose],offset: SIMD3<Float>) {
        guard time.isFinite,!pose.isEmpty,time>(samples.last?.time ?? -.infinity) else { return }
        samples.append(Sample(time:time,pose:pose,offset:offset))
        samples.removeAll { time-$0.time>5 }
        if samples.count>480 { samples.removeFirst(samples.count-480) }
    }
    func sample(at time: Double) -> Sample? {
        guard let first=samples.first,time>=first.time,let last=samples.last else { return nil }
        guard time<=last.time+0.05 else { return nil }
        guard time<last.time else { return last }
        var lo=0,hi=samples.count-1
        while hi-lo>1 {
            let mid=(lo+hi)/2
            if samples[mid].time<=time { lo=mid } else { hi=mid }
        }
        let a=samples[lo],b=samples[hi],f=Float((time-a.time)/(b.time-a.time))
        return Sample(time:time,pose:zip(a.pose,b.pose).map { $0.blended(to:$1,fraction:f) },
                      offset:a.offset+(b.offset-a.offset)*f)
    }
    func applying(to replay: ShotReplay,origin: Double,library: MotionLibrary) -> ShotReplay {
        let idle=library.clips["ready"]!.pose(0)
        var catchOffset=SIMD3<Float>.zero
        if replay.outcome == .caught,let contact=replay.contactTime,
           let recorded=sample(at:origin+contact) {
            let world=library.world(recorded.pose)
            let centre=(library.palm("L",in:world)+library.palm("R",in:world))/2+recorded.offset
            catchOffset=replay.frame(contact).ball-centre
        }
        // Keep a caught ball attached to the recorded hands, not the forecast hands.
        let frames=replay.frames.map { frame in
            let recorded=sample(at:origin+frame.time)
            let pose=recorded?.pose ?? idle,offset=recorded?.offset ?? .zero
            var ball=frame.ball
            if frame.outcome == .caught {
                let world=library.world(pose)
                ball=(library.palm("L",in:world)+library.palm("R",in:world))/2+offset+catchOffset
            }
            return ReplayFrame(time:frame.time,pose:pose,offset:offset,ball:ball,
                ballRotation:frame.ballRotation,outcome:frame.outcome,net:frame.net)
        }
        return ShotReplay(settings:replay.settings,action:replay.action,frames:frames,
            contactTime:replay.contactTime,decisionTime:replay.decisionTime,outcome:replay.outcome)
    }
}
#endif
