#if DEBUG && BALL_DETECTION_DEBUG
import Combine
import QuartzCore

@MainActor final class GoalChallengeSession: ObservableObject {
    @Published private(set) var mode: GoalChallengeMode?
    @Published private(set) var round: GoalChallengeRound?
    @Published private(set) var running=false
    @Published private(set) var epoch=0.0
    private var pausedElapsed=0.0
    private var frozenAt: Double?
    var goalAspect=3.0
    var displayLead=0.20
    var title: String { mode?.title ?? "Virtual Penalties" }
    var finished: Bool { round?.finished == true }
    var activeSeconds: Double { max(0,running ? CACurrentMediaTime()-epoch:pausedElapsed) }
    func select(_ mode: GoalChallengeMode?) {
        self.mode=mode;reset()
    }
    func reset() {
        round=mode.map { GoalChallengeRound(mode:$0) };running=false
        epoch=CACurrentMediaTime();pausedElapsed=0;frozenAt=nil
    }
    func start(at now: Double=CACurrentMediaTime()) {
        guard mode != nil else { return }
        if finished { reset() }
        epoch=now-pausedElapsed;frozenAt=nil;running=true
    }
    func pause(at now: Double=CACurrentMediaTime()) {
        guard running else { return }
        pausedElapsed=now-epoch;frozenAt=now;running=false
    }
    func blockerCentre(at time: Double) -> Double {
        GoalChallengeRules.blockerCentre(elapsed:(frozenAt ?? (running ? time:epoch+pausedElapsed))-epoch)
    }
    func accepting(at time: Double) -> Bool { running && round?.accepting(at:time) == true }
    @discardableResult
    func contact(u: Double,v: Double,radiusU: Double,radiusV: Double,at time: Double,confirmedAt now: Double) -> Bool {
        guard running,var updated=round,
              let shot=updated.hit(u:u,v:v,radiusU:radiusU,radiusV:radiusV,goalAspect:goalAspect,
                                   contactTime:time,confirmedAt:now,displayLead:displayLead,epoch:epoch) else { return false }
        round=updated
        WallTargetsFeedback.shared.play(cleared:updated.finished && updated.score>0)
        if updated.finished { pause(at:now) }
        persist()
        return shot.points>0
    }
    var snapshot: [String:Any] {
        ["mode":mode?.rawValue ?? "keeper","score":round?.score ?? 0,"running":running,
         "shots":round?.shots.map { shot in
            ["shot":shot.id,"u":shot.u,"v":shot.v,"contactTime":shot.contactTime,
             "confirmedAt":shot.confirmedAt,"displayTime":shot.displayTime,"points":shot.points,
             "blockerCentre":shot.blockerCentre as Any? ?? NSNull(),"result":shot.label] as [String:Any]
         } ?? [],"displayLead":displayLead,"goalAspect":goalAspect,
         "rule":"confirmed-wall-contact-visible-frame-v1"]
    }
    private func persist() {
        let directory=URL.documentsDirectory.appendingPathComponent("GoalChallenges")
        guard let data=try? JSONSerialization.data(withJSONObject:snapshot,options:[.prettyPrinted,.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try? data.write(to:directory.appendingPathComponent("latest-round.json"),options:.atomic)
    }
}
#endif
