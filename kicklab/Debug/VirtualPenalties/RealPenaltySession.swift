#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import Combine
import QuartzCore
import CoreMotion

@MainActor final class RealPenaltySession: ObservableObject {
    enum Phase: String { case inspect,finding,corners,focusing,reference,countdown,ready,playing }
    @Published private(set) var phase: Phase = .inspect
    @Published private(set) var corners: [CGPoint] = []
    @Published private(set) var message="Set the goal height, then start guided setup."
    @Published private(set) var referenceProgress=0.0
    @Published private(set) var holdTargetHidden=false
    @Published private(set) var completedHolds: [Double]=[]
    @Published private(set) var searchDotsVisible=false
    @Published private(set) var searchCountdown: Int?
    @Published private(set) var canUseManualCorners=false
    @Published private(set) var countdown: Int?
    @Published private(set) var reactionCount=0
    @Published private(set) var predictedPoint: CGPoint?
    @Published var showTrackedBall=true
    // Review estimate, adjustable for the actual projector connection. This is
    // prediction ahead of delivery, not a measured or guaranteed transport delay.
    @Published var displayLead=0.20
    private(set) var flight=PhysicalBallFlight(wallDiameter:0)
    var calibratedBoard: WallBoard? { board }
#if targetEnvironment(simulator)
    private var previewFlightClock: Double?
#endif
    func flightFrame(at time: Double) -> PhysicalBallFlight.Frame? {
#if targetEnvironment(simulator)
        if let previewFlightClock { return flight.frame(at:previewFlightClock,displayLead:displayLead) }
#endif
        return flight.frame(at:time,displayLead:displayLead)
    }
    private(set) var wallDiameter: Double?
    private var board: WallBoard?
    private var hold: PhysicalCalibrationHold?
    var referenceBallGate: PhysicalCalibrationHold? { phase == .reference ? hold:nil }
    private var holdExpiry=Double.infinity
    var imageAspect=16.0/9.0
    var imageWidth=1280.0
    private var contacts: WallImpactDetector?
    private var recentPoints: [PhysicalShotPoint]=[]
    private var resultLog: [[String:Any]]=[]
    private var lastSampleTime: Double?
    private func prepareContacts() {
        guard let wallDiameter else { return }
        let pixels=corners.map { CGPoint(x:$0.x*imageWidth,y:$0.y*imageWidth/imageAspect) }
        if pixels.count==4,let board=WallBoard(topLeft:pixels[0],topRight:pixels[1],bottomRight:pixels[2],bottomLeft:pixels[3]),
           let reference=WallBallReference([wallDiameter]) {
            contacts=WallImpactDetector(board:board,reference:reference,imageWidth:imageWidth,
                layout:WallTargetLayout(id:"penalty-goalmouth-v1",targets:[],continuousSurface:true))
            contacts?.processingFPS=30
        }
    }
    private var predictor=PhysicalBallPredictor(wallDiameter:0)
    private var armedAt=Double.infinity
    private var lastReaction: [Double]?
    private var reactionLog: [[Double]]=[]
    private let motion=CMMotionManager()
    private var movedSince: Double?
    let keeper: KeeperScene
    let challenge: GoalChallengeSession
    static let cornerNames=["top-left","top-right","bottom-right","bottom-left"]
    var armed: Bool { phase == .playing }
    var settingUp: Bool { [.finding,.corners,.focusing,.reference,.countdown].contains(phase) }
    var targetIndex: Int? {
        phase == .reference && PhysicalCalibrationTarget.points.indices.contains(completedHolds.count)
            ? completedHolds.count:nil
    }
    var targetName: String { targetIndex.map { PhysicalCalibrationTarget.names[$0] } ?? "" }
    var setupTitle: String {
        switch phase {
        case .inspect: return "Set up your goal"
        case .finding: return searchCountdown.map { "Stand aside · checking in \($0)" } ?? "Finding the goal · stay still"
        case .corners: return "Tap corner \(corners.count+1) of 4"
        case .focusing: return "Goal found · stand aside"
        case .reference: return "One ball hold · centre ring"
        case .countdown: return "Setup complete · step back"
        case .ready: return "Ready when you are"
        case .playing: return challenge.mode?.title ?? "Real penalties"
        }
    }
    var cameraTargets: [CGPoint] {
        guard let board else { return [] }
        return PhysicalCalibrationTarget.points.map { board.imagePoint(u:$0.x*3,v:$0.y*2) }
    }

    init(keeper: KeeperScene,challenge: GoalChallengeSession) { self.keeper=keeper;self.challenge=challenge }

    func invalidate(_ reason: String="Start guided setup before shooting.") {
#if targetEnvironment(simulator)
        previewFlightClock=nil
#endif
        motion.stopDeviceMotionUpdates();movedSince=nil
        challenge.reset()
        phase = .inspect;corners=[];board=nil;wallDiameter=nil
        hold=nil;referenceProgress=0;completedHolds=[];countdown=nil;holdTargetHidden=false;holdExpiry = .infinity
        searchDotsVisible=false;searchCountdown=nil;canUseManualCorners=false
        armedAt = .infinity;predictor.reset();flight.reset();predictedPoint=nil
        contacts=nil;recentPoints=[];lastSampleTime=nil
        keeper.showPhysicalReference(false);keeper.reset()
        message=reason
    }
    func beginCalibration() {
        invalidate()
        phase = .finding
        searchCountdown=3
        keeper.showPhysicalReference(true)
        message="Stand beside the camera. Keep the whole goal visible."
        watchPhoneMovement()
    }
    func showSearchDots(_ visible: Bool) {
        guard phase == .finding else { return }
        searchDotsVisible=visible
    }
    func prepareSearch(_ number: Int?) {
        guard phase == .finding else { return }
        searchCountdown=number
    }
    func foundGoal(_ points: [CGPoint]?) {
        guard phase == .finding else { return }
        searchDotsVisible=false;searchCountdown=nil
        guard let points,WallBoard.validCalibration(points) else {
            invalidate("Could not see all four markers. Stand clear of the goal and retry.")
            canUseManualCorners=true
            return
        }
        corners=points
        prepareHolds()
    }
    func beginManualCalibration() {
        invalidate()
        phase = .corners
        keeper.showPhysicalReference(true)
        message="Tap the top-left inside corner of the goal in the camera view."
        watchPhoneMovement()
    }
    func addCorner(_ p: CGPoint) {
        guard phase == .corners,corners.count<4,(0...1).contains(p.x),(0...1).contains(p.y) else { return }
        corners.append(p)
        if corners.count<4 { message="Tap the \(Self.cornerNames[corners.count]) inside corner.";return }
        guard WallBoard.validCalibration(corners),
              let mapped=WallBoard(topLeft:corners[0],topRight:corners[1],bottomRight:corners[2],bottomLeft:corners[3]) else {
            corners=[];message="Corners crossed or too small. Start with the top-left corner.";return
        }
        board=mapped
        prepareHolds()
    }
    private func prepareHolds() {
        guard corners.count==4 else { return }
        board=WallBoard(topLeft:corners[0],topRight:corners[1],bottomRight:corners[2],bottomLeft:corners[3])
        phase = .focusing
        keeper.showPhysicalReference(true)
        message="Stand clear while the camera focuses on the goal."
    }
    func referenceFocusFinished(_ success: Bool) {
        guard phase == .focusing else { return }
        guard success else { invalidate("Could not lock focus. Keep the goal visible and restart setup.");return }
        phase = .reference
        prepareNextHold()
    }
    private func prepareNextHold() {
        guard let board,completedHolds.count<PhysicalCalibrationTarget.points.count else { return }
        let point=PhysicalCalibrationTarget.points[completedHolds.count]
        let target=board.imagePoint(u:point.x*3,v:point.y*2)
        let left=board.imagePoint(u:(point.x-0.07)*3,v:point.y*2)
        let right=board.imagePoint(u:(point.x+0.07)*3,v:point.y*2)
        let radius=max(0.008,hypot(right.x-left.x,(right.y-left.y)/imageAspect)/2)
        hold=PhysicalCalibrationHold(target:[target.x,target.y],radius:radius,imageAspect:imageAspect)
        referenceProgress=0;holdTargetHidden=false;holdExpiry = .infinity
        message="Hold the ball against the wall in the centre ring. Keep it there until the ring fills."
    }
    func countDown(_ number: Int) {
        guard phase == .countdown else { return }
        countdown=number
        message="Step back with the ball. Starting in \(number)…"
    }
    func start() {
        guard phase == .ready || phase == .countdown,let wallDiameter,keeper.ready else { return }
        challenge.goalAspect=keeper.projectedGoalAspect
        challenge.displayLead=displayLead
        challenge.start()
        let gravity=PhysicalBallArc.gravityPrior(wallDiameter:wallDiameter,imageAspect:imageAspect)
        predictor=PhysicalBallPredictor(wallDiameter:wallDiameter,verticalGravity:gravity)
        flight=PhysicalBallFlight(wallDiameter:wallDiameter,verticalGravity:gravity)
        if let board {
            let centre=board.imagePoint(u:1.5,v:1)
            let right=board.boardPoint(CGPoint(x:centre.x+wallDiameter/2,y:centre.y))
            let down=board.boardPoint(CGPoint(x:centre.x,y:centre.y+wallDiameter*imageAspect/2))
            let radius=Float(min(abs(right.x-1.5)*7.32/3,abs(down.y-1)*2.44/2))
            keeper.physicalBallRenderRadius=clamp(radius,0.11,0.30)
        }
        keeper.setPhysicalDisplayLead(displayLead)
        prepareContacts()
        recentPoints=[];lastSampleTime=nil
        armedAt=CACurrentMediaTime();phase = .playing;countdown=nil
        message="Ready — shoot the real ball.";predictedPoint=nil
        keeper.showPhysicalReference(false)
        watchPhoneMovement()
    }
    /// Reuse this goal's reference only while its motion/output monitors remain
    /// valid. The countdown gives capture time to resume before another shot.
    func prepareChallengeRound() {
        guard challenge.mode != nil, wallDiameter != nil, armed || phase == .ready else { return }
        pause(); challenge.reset(); phase = .countdown; countdown=5
    }

    func newChallengeRound() {
        guard challenge.mode != nil,wallDiameter != nil,armed || phase == .ready else { return }
        pause();challenge.reset();start()
    }
    func pause() {
        guard armed || phase == .countdown else { return }
        challenge.pause()
        phase = .ready;armedAt = .infinity;predictor.reset();flight.reset()
        contacts=nil;recentPoints=[];lastSampleTime=nil
        keeper.showPhysicalReference(false);keeper.reset();predictedPoint=nil;countdown=nil
        message="Paused — resume with the phone and projector in the same position."
    }

    func consume(_ sample: PhysicalBallSample?,at time: Double) -> PhysicalKeeperTelemetry {
        let now=CACurrentMediaTime()
        guard now-time>=0,now-time<0.20 else { return telemetry }
        if phase == .reference {
            if !holdTargetHidden {
                if let sample,hold?.contains(sample) == true {
                    holdTargetHidden=true
                    // Remove the projected marker and let the wireless display
                    // settle before measuring. A detected graphic disappears;
                    // the physical ball must remain, with new evidence.
                    hold?.beginMeasurement(after:now+0.9)
                    holdExpiry=now+2.9
                    message="Keep the ball touching the wall while the marker clears."
                }
                return telemetry
            }
            let measured=hold?.consume(sample,at:time)
            referenceProgress=hold?.progress ?? 0
            if let hold { message=hold.message }
            if referenceProgress>0 { holdExpiry=now+2 }
            if referenceProgress==0,now>holdExpiry {
                prepareNextHold()
                message="Place the real ball inside the ring and keep it touching the wall."
            }
            if let measured {
                completedHolds.append(measured)
                if completedHolds.count == PhysicalCalibrationTarget.points.count {
                    // The auto-detected/manual corners already define the goal.
                    // The centre hold supplies the existing wall-depth scale.
                    wallDiameter=measured;hold=nil;referenceProgress=1
                    phase = .countdown;countdown=5
                    message="Ball measured. Step back with the ball."
                } else { prepareNextHold() }
            }
        } else if armed,time>=armedAt,let board {
            // The large result lettering must never become ball evidence.
            // Resume fresh tracking for the replay, which a new shot can interrupt.
            if challenge.mode != nil ? !challenge.accepting(at:time) : !keeper.acceptingPhysicalShot {
                flight.reset();predictor.reset();contacts=nil;recentPoints=[];lastSampleTime=nil
                return telemetry
            }
            if contacts == nil { prepareContacts() }
            if let previous=lastSampleTime,time>previous,time-previous<0.15 {
                let fps=0.85*(contacts?.processingFPS ?? 30)+0.15/(time-previous)
                contacts?.processingFPS=fps
            }
            lastSampleTime=time
            if let sample,sample.usable,sample.hasUnclippedBounds {
                let point=board.boardPoint(CGPoint(x:sample.x,y:sample.y))
                let goal=SIMD2<Float>(Float((point.x/3-0.5)*7.32),Float((1-point.y/2)*2.44))
                recentPoints.append(PhysicalShotPoint(time:time,goal:goal,depth:Float((wallDiameter ?? 0)/sample.diameter)))
                contacts?.add(.init(t:time,x:sample.x*imageWidth,y:sample.y*imageWidth/imageAspect,
                    d:sample.diameter*imageWidth,hand:sample.held ? .held:sample.released ? .clear:.unknown))
            }
            recentPoints.removeAll { time-$0.time>1.6 }
            if challenge.mode != nil {
                for impact in contacts?.impacts(now:time) ?? [] where time-impact.t<1 {
                    let radius=impact.d/imageWidth/2
                    let right=board.boardPoint(CGPoint(x:impact.x/imageWidth+radius,y:impact.y*imageAspect/imageWidth))
                    let down=board.boardPoint(CGPoint(x:impact.x/imageWidth,y:impact.y*imageAspect/imageWidth+radius*imageAspect))
                    _=challenge.contact(u:impact.u/3,v:impact.v/2,
                        radiusU:abs(right.x-impact.u)/3,radiusV:abs(down.y-impact.v)/2,
                        at:impact.t,confirmedAt:now)
                    contacts=nil;recentPoints=[]
                    message=challenge.finished ? "Round complete · \(challenge.round?.score ?? 0) points" : "Retrieve the ball · next shot when ready"
                }
                return telemetry
            }
            flight.consume(sample,at:time)
            if let prediction=predictor.consume(sample,at:time,automaticallyCommit:false) {
                let goal=board.boardPoint(CGPoint(x:prediction.image.x,y:prediction.image.y))
                let target=SIMD2<Float>(Float((goal.x/3-0.5)*7.32),Float((1-goal.y/2)*2.44))
                let lead=prediction.arrival-now
                if goal.x.isFinite,goal.y.isFinite,(-0.5...3.5).contains(goal.x),
                   (-0.7...2.4).contains(goal.y),lead>0.025,
                   keeper.reactToPhysicalBall(target:target,lead:lead,observedAt:time,displayLead:displayLead) {
                    predictor.commit(prediction)
                    predictedPoint=CGPoint(x:prediction.image.x,y:prediction.image.y)
                    reactionCount += 1
                    predictor.waitForRecovery(until:now+keeper.physicalRecoveryDuration+0.10)
                    message="\(keeper.action) · reaction \(reactionCount)"
                    lastReaction=[time,now,prediction.arrival,Double(target.x),Double(target.y),lead,Double(prediction.samples)]
                    reactionLog.append(lastReaction!)
                    if reactionLog.count>100 { reactionLog.removeFirst() }
                    saveReactionLog()
                } else {
                    // Rejected proposals do not consume this approach. Later
                    // observations may correct a rising ball's landing point.
                    message=lead<=0.025 ? "Read too late for this shot." : "Still checking the shot or waiting for keeper recovery."
                }
            }
            if let refined=predictor.refinement {
                let goal=board.boardPoint(CGPoint(x:refined.image.x,y:refined.image.y))
                if goal.x.isFinite,goal.y.isFinite {
                    keeper.refinePhysicalAim([Float((goal.x/3-0.5)*7.32),Float((1-goal.y/2)*2.44)],
                        arrival:refined.arrival,observedAt:time)
                    predictedPoint=CGPoint(x:refined.image.x,y:refined.image.y)
                }
            }
            if let preparation=predictor.preparation {
                let goal=board.boardPoint(CGPoint(x:preparation.image.x,y:preparation.image.y))
                if goal.x.isFinite,goal.y.isFinite,(-0.5...3.5).contains(goal.x),(-0.7...2.4).contains(goal.y) {
                    keeper.prepareForPhysicalBall(target:[Float((goal.x/3-0.5)*7.32),Float((1-goal.y/2)*2.44)])
                }
            }
            for impact in contacts?.impacts(now:time) ?? [] where time-impact.t<1 {
                let hit=SIMD2<Float>(Float((impact.u/3-0.5)*7.32),Float((1-impact.v/2)*2.44))
                let radius=impact.d/imageWidth/2
                let right=board.boardPoint(CGPoint(x:impact.x/imageWidth+radius,y:impact.y/imageWidth*imageAspect))
                let down=board.boardPoint(CGPoint(x:impact.x/imageWidth,y:impact.y/imageWidth*imageAspect+radius*imageAspect))
                let r=Float(min(abs(right.x-impact.u)*7.32/3,abs(down.y-impact.v)*2.44/2))
                if let result=keeper.finishPhysicalShot(points:recentPoints,contact:impact.t,hit:hit,radius:r) {
                    flight.reset();predictor.reset()
                    message="\(result.rawValue) · finishing the shot"
                    resultLog.append(["contactTime":impact.t,"confirmedAt":now,"goal":[hit.x,hit.y],
                                      "result":result.rawValue,"basis":"measured-wall-hit-recorded-display-pose",
                                      "contactEvidence":keeper.physicalContactEvidence,
                                      "playback":keeper.physicalReviewTiming])
                    if resultLog.count>100 { resultLog.removeFirst() }
                    saveReactionLog()
                }
            }
        }
        return telemetry
    }
    var telemetry: PhysicalKeeperTelemetry {
        PhysicalKeeperTelemetry(state:phase.rawValue,armed:armed,reactions:reactionCount,trackingReason:predictor.reason,
            corners:corners.map { [Double($0.x),Double($0.y)] },wallDiameter:wallDiameter,lastReaction:lastReaction,
            instruction:message,setupTarget:targetIndex,setupProgress:referenceProgress,completedHolds:completedHolds,
            countdown:countdown,setupMarkerHidden:holdTargetHidden,
            trackedBall:showTrackedBall,displayLead:displayLead,flightReason:flight.reason,
            flightStartedAt:flight.lastStartedAt,virtualResult:keeper.reviewResult?.rawValue,reviewStage:keeper.reviewStage,
            ballSkin:keeper.ballSkin.rawValue)
    }
    private func saveReactionLog() {
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("KeeperLive")
        let data: [String:Any]=["columns":["cameraTime","decisionTime","predictedArrival","goalX","goalY","leadSeconds","samples"],
                              "reactions":reactionLog,"calibration":telemetry.json,"saveScoring":"virtual-coverage",
                              "results":resultLog]
        if let encoded=try? JSONSerialization.data(withJSONObject:data,options:.sortedKeys) {
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try? encoded.write(to:directory.appendingPathComponent("reactions.json"),options:.atomic)
        }
    }
#if targetEnvironment(simulator)
    /// Explicit visual-QA state; never compiled into the physical iPhone build.
    func previewSetup(_ name: String) {
        beginCalibration()
        if name == "finding" { searchDotsVisible=true;searchCountdown=nil;return }
        foundGoal([CGPoint(x:0.15,y:0.2),CGPoint(x:0.85,y:0.2),CGPoint(x:0.85,y:0.85),CGPoint(x:0.15,y:0.85)])
        referenceFocusFinished(true)
        if name == "challenge" {
            completedHolds=[0.036];wallDiameter=0.036
            phase = .ready;start()
            return
        }
        if name == "flight" {
            corners=[CGPoint(x:0.2164,y:0.1376),CGPoint(x:0.6799,y:0.1482),
                     CGPoint(x:0.6743,y:0.5004),CGPoint(x:0.2611,y:0.5559)]
            board=WallBoard(topLeft:corners[0],topRight:corners[1],bottomRight:corners[2],bottomLeft:corners[3])
            wallDiameter=0.036;phase = .playing;keeper.showPhysicalReference(false)
            flight=PhysicalBallFlight(wallDiameter:0.036)
            for (t,q): (Double,Double) in [(100,0.32),(100.06,0.40)] {
                flight.consume(PhysicalBallSample(time:t,x:0.55-0.10*(1-q)/q,
                    y:0.30+0.20*(1-q)/q,diameter:0.036/q,confidence:0.95,aspect:1),at:t)
            }
            previewFlightClock=100.12
            return
        }
        completedHolds=[]
        prepareNextHold();referenceProgress=name == "locating" ? 0:0.62;holdTargetHidden=name != "locating"
        if name == "countdown" { completedHolds=[0.036];phase = .countdown;countdown=3 }
    }
#endif
    private func watchPhoneMovement() {
        guard motion.isDeviceMotionAvailable,!motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval=0.05
        motion.startDeviceMotionUpdates(to:.main) { [weak self] sample,_ in
            guard let sample else { return }
            let rotation=hypot(hypot(sample.rotationRate.x,sample.rotationRate.y),sample.rotationRate.z)
            let acceleration=hypot(hypot(sample.userAcceleration.x,sample.userAcceleration.y),sample.userAcceleration.z)
            Task { @MainActor in
                guard let self,self.phase != .inspect else { return }
                let now=CACurrentMediaTime()
                if rotation>0.12 || acceleration>0.12 {
                    if self.movedSince == nil { self.movedSince=now }
                    if now-(self.movedSince ?? now)>0.2 { self.invalidate("Phone moved — restart guided setup.") }
                } else { self.movedSince=nil }
            }
        }
    }
}
#endif
