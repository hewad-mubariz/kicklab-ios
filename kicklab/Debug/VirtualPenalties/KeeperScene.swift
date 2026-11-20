#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import RealityKit
import Combine
import simd
import UIKit

struct KeeperSurface: UIViewRepresentable {
    let keeper: KeeperScene
    var projected = false
    final class Coordinator {
        let keeper: KeeperScene
        init(_ keeper: KeeperScene) { self.keeper=keeper }
    }
    func makeCoordinator() -> Coordinator { Coordinator(keeper) }
    func makeUIView(context: Context) -> ARView { keeper.makeView(projected:projected) }
    func updateUIView(_ uiView: ARView, context: Context) { keeper.setProjectionMode(projected,for:uiView) }
    static func dismantleUIView(_ uiView: ARView,coordinator: Coordinator) { coordinator.keeper.detachView(uiView) }
}

@MainActor final class KeeperScene: ObservableObject {
    @Published private(set) var ready=false
    @Published private(set) var status="Loading training ground"
    @Published private(set) var sideView=false
    @Published private(set) var isPlaying=false
    @Published private(set) var playhead: Double=0
    @Published private(set) var duration: Double=3.4
    @Published private(set) var speed: Double=1
    @Published private(set) var hasShot=false
    @Published private(set) var action="Ready stance"
    @Published private(set) var outcome="Aim your shot"
    @Published var settings=ShotSettings()
    @Published var error: String?
    @Published var ballSkin: BallSkin = {
        let saved=BallSkin(rawValue:UserDefaults.standard.string(forKey:"keeper.ballSkin") ?? "") ?? .classic
        return saved == .original ? .classic:saved
    }() {
        didSet {
            guard ballSkin != oldValue else { return }
            UserDefaults.standard.set(ballSkin.rawValue,forKey:"keeper.ballSkin")
            loadBallSkin()
        }
    }
    @Published private(set) var ballSkinLoading=false
    @Published private(set) var ballSkinError: String?
    @Published private(set) var ballSpinFrames=[CGImage]()
    private var ballSkinTask: Task<Void,Never>?
    @Published private(set) var demoRunning=false
    @Published private(set) var reviewActive=false
    @Published private(set) var reviewStage=""
    @Published private(set) var reviewResult: ShotOutcome?
    @Published private(set) var reviewCurtain=0.0
    private var reviewStarted=0.0
    private var reviewPlayback: PhysicalShotPlayback?
    private var reviewOrigin=0.0
    private var reviewPosesFinalized=false
    private var poseHistory=PhysicalPoseHistory()
    private var shownPose=[BonePose]()
    private(set) var physicalContactEvidence: [String:Any]=[:]
    private let automaticPhysicalReplay=false
    var acceptingPhysicalShot: Bool { !reviewActive || reviewStage == "Replay" }
    var showingReplay: Bool { ["Replay","Transition","Returning"].contains(reviewStage) }
    var physicalReviewTiming: [String:Double] {
        guard let flow=reviewPlayback else { return [:] }
        if !automaticPhysicalReplay {
            return ["resultStarted":flow.confirmedAt,"readyAt":flow.confirmedAt+flow.finishDuration,
                    "automaticReplay":0]
        }
        return ["resultStarted":flow.confirmedAt,"gestureStarts":flow.confirmedAt+flow.finishDuration,
                "replayStarts":flow.confirmedAt+flow.replayBegins,"replaySpeed":PhysicalShotPlayback.replaySpeed,
                "returnStarts":flow.confirmedAt+flow.returnBegins]
    }
    private var lastPhysicalAttempt: (motion:PhysicalKeeperMotion,started:Double)?
#if targetEnvironment(simulator)
    private var reviewFrozenAge: Double?
    private var flowAudit=[[String:Any]]()
    private var flowInterrupted=false
#endif
    @Published var projectionScale: Float=1 { didSet { updateCamera() } }
    @Published var brightProjection=true { didSet { configureDisplay() } }
    @Published var projectionPreview=false
    @Published var physicalGoalHeight: Float=1.22 { didSet { updatePhysicalHeight() } }
    @Published private(set) var outputRevision=0
    @Published private(set) var projectedGoalCorners: [CGPoint]=[]
    private let stage=AnchorEntity(world:.zero),camera=PerspectiveCamera(),ball=ModelEntity(),target=Entity()
    private let worldContent=Entity()
    private let physicalBackdrop=ModelEntity()
    private var actor: Entity?,body: ModelEntity?,library: MotionLibrary?,replayData: ShotReplay?
    private var boneOrder=[Int](),updates:(any Cancellable)?,idleTime: Double=0
    private var loadTask: Task<Void,Never>?
    private var goalNet: GoalNet?
    var hasNetImpact: Bool { replayData?.frames.last?.net.isEmpty == false }
    private weak var currentView: ARView?
    private var builtEnvironment=false,isProjected=false
    private var displaySuspended=false
    private var physicalBallMode=false
    private var physicalReference=false
    private var goalChallenge: GoalChallengeSession?
    private var robot: Entity?
    private var robotTask: Task<Void,Never>?
    var projectedGoalAspect: Double {
        guard projectedGoalCorners.count==4,let view=currentView else { return 3 }
        let width=abs(projectedGoalCorners[1].x-projectedGoalCorners[0].x)*view.bounds.width
        let height=abs(projectedGoalCorners[3].y-projectedGoalCorners[0].y)*view.bounds.height
        return Double(width/max(1,height))
    }
    func setGoalChallenge(_ session: GoalChallengeSession?) {
        goalChallenge=session
        reset();showPhysicalReference(physicalReference)
        if session?.mode == .findSpace,robot == nil,robotTask == nil {
            robotTask=Task { [weak self] in
                guard let self else { return }
                defer { self.robotTask=nil }
                do {
                    guard let bundleURL=Bundle.main.url(forResource:"GoalChallengeAssets",withExtension:"bundle"),
                          let assets=Bundle(url:bundleURL),let url=assets.url(forResource:"Robot",withExtension:"usdz") else { throw LoadError.missing }
                    let entity=try await Entity(contentsOf:url)
                    entity.orientation=simd_quatf(angle:.pi,axis:[0,1,0])
                    entity.stopAllAnimations(recursive:true)
                    self.robot=entity;self.worldContent.addChild(entity)
                    self.showPhysicalReference(self.physicalReference)
                } catch { self.error="Robot asset could not be loaded: \(error.localizedDescription)" }
            }
        }
    }
    private var physicalMotion: PhysicalKeeperMotion?
    private var physicalTiming: PhysicalSaveTiming?
    private var physicalGripStarted: Double?
    private var physicalGripRelativeCentre=SIMD3<Float>.zero
    private var physicalPreparation: (target:SIMD2<Float>,started:Double,updated:Double)?
    private var physicalMotionStarted=0.0
    private var physicalMotionReceived=0.0
    private var physicalDisplayLead=0.0
    private var physicalEntryPose: [BonePose]?
    private var physicalEntryOffset=SIMD3<Float>.zero
    var physicalBallRenderRadius: Float=0.0935
    var physicalRecoveryDuration: Double { (physicalMotion?.duration ?? 0)+0.2 }
    func setPhysicalDisplayLead(_ seconds: Double) { physicalDisplayLead=clamp(seconds,0,0.25) }
    func prepareForPhysicalBall(target: SIMD2<Float>) {
        guard physicalBallMode,!physicalReference,!reviewActive,physicalMotion == nil,
              target.x.isFinite,target.y.isFinite else { return }
        let now=CACurrentMediaTime()
        physicalPreparation=(target,physicalPreparation?.started ?? now,now)
    }
    private var viewportSize=CGSize.zero
    private var demoIndex=0,demoDelay: Double=0

    func makeView(projected: Bool=false) -> ARView {
        // One renderer owns the stage. Connecting or removing an external screen
        // transfers it, preserving the shot, mesh, playback clock and loaded rig.
        if let old=currentView { detachView(old) }
        let v=ARView(frame:.zero,cameraMode:.nonAR,automaticallyConfigureSession:false)
        currentView=v;isProjected=projected;configureDisplay()
        v.renderOptions=[.disableMotionBlur,.disableDepthOfField,.disableCameraGrain,.disableAREnvironmentLighting]
        v.scene.addAnchor(stage)
        if !builtEnvironment {
            stage.addChild(camera);stage.addChild(worldContent);TrainingGround.build(in:worldContent);buildBall()
            physicalBackdrop.model=ModelComponent(mesh:.generateBox(size:[10,4,0.02]),
                materials:[UnlitMaterial(color:UIColor(red:0.015,green:0.025,blue:0.022,alpha:1))])
            physicalBackdrop.position=[0,2,-3.5]
            physicalBackdrop.isEnabled=physicalBallMode
            worldContent.addChild(physicalBackdrop)
            do { goalNet=try GoalNet(in:worldContent) } catch { self.error="The goal net could not be loaded: \(error.localizedDescription)" }
            builtEnvironment=true
        }
        updateCamera()
        updates=v.scene.subscribe(to:SceneEvents.Update.self) { [weak self,weak v] event in
            Task { @MainActor in
                guard let self,let v,self.currentView === v,!self.displaySuspended else { return }
                self.advance(event.deltaTime)
            }
        }
#if WALL_GAMES_PREVIEW
        // Top Bins needs the goal, not the retained animated human rig.
        if goalChallenge?.mode == .topBins { ready=true;status="Top Bins ready" }
        else if !ready && loadTask == nil { loadTask=Task { await loadKeeper() } }
#else
        if !ready && loadTask == nil { loadTask=Task { await loadKeeper() } }
#endif
        if ready && hasShot && !reviewActive { applyFrame() }
        return v
    }
    func detachView(_ view: ARView) {
        guard currentView === view else { return }
        updates?.cancel();updates=nil;view.scene.removeAnchor(stage);currentView=nil
    }
    func setProjectionMode(_ projected: Bool,for view: ARView) {
        guard currentView === view,isProjected != projected else { return }
        isProjected=projected;configureDisplay();updateCamera()
    }
    private func configureDisplay() {
        currentView?.environment.background = .color(isProjected ? .black:UIColor(red:0.055,green:0.105,blue:0.16,alpha:1))
        currentView?.environment.lighting.intensityExponent = isProjected && brightProjection ? 0.35:-0.2
    }
    func suspend() { demoRunning=false;isPlaying=false;displaySuspended=true }
    func resumeDisplay() { displaySuspended=false }
    func stop() {
        reset()
        if let view=currentView { detachView(view) }
    }
    func setPhysicalBallMode(_ enabled: Bool) {
        physicalBallMode=enabled
        physicalBackdrop.isEnabled=enabled
        updatePhysicalHeight()
        reset()
    }
    private func updatePhysicalHeight() {
        worldContent.scale=[1,physicalBallMode ? physicalGoalHeight:1,1]
        outputRevision += 1
    }
    func showPhysicalReference(_ visible: Bool) {
        physicalReference=visible
        actor?.isEnabled = !visible && goalChallenge == nil
        robot?.isEnabled = !visible && goalChallenge?.mode == .findSpace
        // Setup rings are drawn on the projector and phone from the same goal
        // geometry. Avoid a second target beneath the real ball.
        target.isEnabled=false
    }
    @discardableResult
    func reactToPhysicalBall(target: SIMD2<Float>,lead: Double,observedAt: Double?=nil,displayLead: Double=0) -> Bool {
        guard physicalBallMode,!physicalReference,!displaySuspended,physicalMotion == nil,acceptingPhysicalShot,
              let library,target.x.isFinite,target.y.isFinite,lead.isFinite,lead>0 else { return false }
        let entry=shownPose,entryOffset=actor?.position ?? .zero
        physicalPreparation=nil
        if reviewActive {
            reset()
            if !entry.isEmpty { applyPose(entry);actor?.position=entryOffset }
        }
        let now=CACurrentMediaTime()
        let capture=observedAt.map { clamp($0,now-0.20,now) } ?? now
        let motion=PhysicalKeeperMotion(library:library,target:target,lead:lead+(now-capture))
        physicalMotion=motion;physicalMotionStarted=capture;physicalMotionReceived=now
        physicalTiming=PhysicalSaveTiming(motion:motion,startedAt:capture,arrival:now+lead)
        physicalGripStarted=nil
        lastPhysicalAttempt=(motion,capture)
        physicalDisplayLead=clamp(displayLead,0,0.25)
        physicalEntryPose=entry.isEmpty ? library.clips["ready"]!.pose(0):entry
        physicalEntryOffset=entryOffset
        poseHistory.append(time:now+physicalDisplayLead,pose:physicalEntryPose!,offset:entryOffset)
        action=motion.action;status=motion.reachTime>lead+0.05 ? "Late read · attempting the save":"Reacting to your ball"
        ball.isEnabled=false;self.target.isEnabled=false
        return true
    }
    func refinePhysicalAim(_ target: SIMD2<Float>,arrival: Double?=nil,observedAt: Double?=nil) {
        guard !reviewActive else { return }
        physicalMotion?.refine(target)
        if let arrival,let observedAt { physicalTiming?.refine(arrival:arrival,observedAt:observedAt) }
        if let motion=physicalMotion { lastPhysicalAttempt=(motion,physicalMotionStarted) }
        if let updated=physicalMotion?.action,action != updated { action=updated }
    }
    @discardableResult
    func finishPhysicalShot(points: [PhysicalShotPoint],contact: Double,hit: SIMD2<Float>,radius: Float) -> ShotOutcome? {
        guard physicalBallMode,!physicalReference,!reviewActive,let library else { return nil }
        let attempt=lastPhysicalAttempt.flatMap {
            contact >= $0.started && contact-$0.started <= $0.motion.duration+0.1 ? $0:nil
        }
        let displayed=poseHistory.sample(at:contact)
        physicalContactEvidence=["contactTime":contact,"recordedPoseAvailable":displayed != nil,
            "assumedDisplayLead":physicalDisplayLead,"measuredBallRadius":radius,
            "refinedArrival":physicalTiming?.arrival as Any? ?? NSNull()]
        if let displayed {
            let world=library.world(displayed.pose)
            physicalContactEvidence["palms"]=["L","R"].map {
                let p=library.palm($0,in:world)+displayed.offset
                return [p.x,p.y,p.z]
            }
        }
        guard let review=PhysicalShotReview.build(library:library,points:points,contact:contact,
            hit:hit,radius:radius,motion:attempt?.motion,motionStarted:attempt?.started ?? contact,
            recordedPose:displayed?.pose,recordedOffset:displayed?.offset ?? .zero,requireRecordedPose:true) else { return nil }
        if review.outcome == .caught,!shownPose.isEmpty {
            physicalGripStarted=CACurrentMediaTime()
            let world=library.world(shownPose)
            physicalGripRelativeCentre=(library.palm("L",in:world)+library.palm("R",in:world))/2
                - library.position("Spine2",in:world)
        }
        replayData=review;duration=review.duration;hasShot=true;isPlaying=false
        reviewActive=true;reviewStage="Result";reviewResult=review.outcome;reviewStarted=CACurrentMediaTime()
        reviewOrigin=contact-(review.contactTime ?? 0)
        reviewPosesFinalized=false
        reviewPlayback=PhysicalShotPlayback(confirmedAt:reviewStarted,contact:contact,
            contactInClip:review.contactTime ?? 0,duration:review.duration,
            liveMotionEnds:physicalTiming.map { $0.recoveryEnds-physicalDisplayLead }
                ?? physicalMotion.map { physicalMotionStarted+$0.duration-physicalDisplayLead } ?? reviewStarted,
            displayLead:physicalDisplayLead,replayEnabled:automaticPhysicalReplay)
        // Keep the live body untouched. Only the ball/net advance to current time.
        playhead=reviewPlayback!.state(at:reviewStarted).time
        outcome=review.outcome.rawValue;status="Finishing your shot"
        return review.outcome
    }
    private func loadKeeper() async {
        do {
            guard let bundleURL=Bundle.main.url(forResource:"KeeperAssets",withExtension:"bundle"),
                  let assets=Bundle(url:bundleURL),
                  let url=assets.url(forResource:"Keeper-ready",withExtension:"usdz"),
                  let data=assets.url(forResource:"motion-library",withExtension:"json") else { throw LoadError.missing }
            let lib=try JSONDecoder().decode(MotionLibrary.self,from:Data(contentsOf:data))
            let entity=try await Entity(contentsOf:url)
            entity.stopAllAnimations(recursive:true)
            guard let model=findBody(entity) else { throw LoadError.skeleton }
            let order=model.jointNames.map { n in lib.names.firstIndex { $0==n || $0.split(separator:"/").last==n.split(separator:"/").last } ?? -1 }
            guard order.count==lib.names.count,!order.contains(-1) else { throw LoadError.skeleton }
            library=lib;actor=entity;body=model;boneOrder=order;worldContent.addChild(entity)
            print("KEEPER_RIG joints=\(model.jointNames.count) model=\(model.name) transform=\(model.transformMatrix(relativeTo:nil))")
            ready=true;status="Choose a target and shoot";reset()
            let args=ProcessInfo.processInfo.arguments
            if args.contains("--slow-motion") { speed=0.25 }
            if args.contains("--side-view") { toggleFraming() }
            if let arg=args.first(where:{$0.hasPrefix("--shot=")}) {
                applyPreset(String(arg.dropFirst(7)));shoot()
            }
            if let arg=args.first(where:{$0.hasPrefix("--read=")}) {
                settings.read=arg.hasSuffix("left") ? .left:.right;shoot()
            }
            if let arg=args.first(where:{$0.hasPrefix("--power=")}),let p=Float(arg.dropFirst(8)) { settings.power=clamp(p,0,1);shoot() }
            if args.contains("--contact") { showContact() }
            if args.contains("--net-impact") { showNetImpact() }
            if let arg=args.first(where:{$0.hasPrefix("--pose-time=")}),let t=Double(arg.dropFirst(12)) { seek(t) }
            if args.contains("--penalty-demo") { toggleDemo() }
#if targetEnvironment(simulator)
            if let arg=args.first(where:{$0.hasPrefix("--physical-flow=")}) {
                setPhysicalBallMode(true)
                let saved=arg.hasSuffix("save"),high=arg.hasSuffix("over")
                Task { @MainActor in
                    try? await Task.sleep(for:.seconds(1))
                    let start=CACurrentMediaTime(),contact=start+0.3
                    let hit=SIMD2<Float>(saved ? 0:high ? -1.76:2.7,saved ? 1.1:high ? 2.79:1.4)
                    let aim=SIMD2<Float>(saved ? 0:-1.6,saved ? 1.1:high ? 2.18:1.4)
                    _=reactToPhysicalBall(target:aim,lead:0.3,observedAt:start,displayLead:0.2)
                    let points=(0...15).map { i in
                        PhysicalShotPoint(time:contact-0.5+Double(i)/30,goal:hit,depth:0.35+Float(i)*0.65/15)
                    }
                    try? await Task.sleep(for:.seconds(0.75))
                    let before=shownPose,offset=actor?.position ?? .zero
                    finishPhysicalShot(points:points,contact:contact,hit:hit,radius:0.15)
                    let jump=zip(before,shownPose).map { simd_length($0.rotation.vector-$1.rotation.vector) }.max() ?? 0
                    auditFlow("confirmation",extra:["rotationJump":jump,"offsetJump":simd_length(offset-(actor?.position ?? .zero))])
                }
            }
            if let arg=args.first(where:{$0.hasPrefix("--physical-result=")}) {
                setPhysicalBallMode(true)
                if let value=args.first(where:{$0.hasPrefix("--physical-radius=")}),
                   let radius=Float(value.dropFirst("--physical-radius=".count)) { physicalBallRenderRadius=radius }
                let contact=CACurrentMediaTime()-0.25
                let saved=arg.hasSuffix("save"),point=SIMD2<Float>(saved ? 0:2.7,saved ? 1.1:1.4)
                if saved {
                    let motion=PhysicalKeeperMotion(library:lib,target:point,lead:0.4)
                    lastPhysicalAttempt=(motion,contact-motion.reachTime)
                    physicalMotion=motion;physicalMotionStarted=contact-motion.reachTime
                    physicalMotionReceived=physicalMotionStarted-0.2
                    for i in 0...90 {
                        let t=contact-0.5+Double(i)/120,f=motion.frame(t-physicalMotionStarted)
                        poseHistory.append(time:t,pose:f.pose,offset:f.offset)
                    }
                }
                let points=(0...12).map { i in
                    PhysicalShotPoint(time:contact-0.4+Double(i)/30,goal:point,depth:0.4+Float(i)*0.05)
                }
                finishPhysicalShot(points:points,contact:contact,hit:point,radius:0.15)
                reviewFrozenAge=args.contains("--review-live") ? nil:
                    args.first(where:{$0.hasPrefix("--review-age=")})
                        .flatMap { Double($0.dropFirst("--review-age=".count)) } ?? 0.3
            }
            if let arg=args.first(where:{$0.hasPrefix("--review-capture=")}) {
                let name=String(arg.dropFirst(17))
                Task { @MainActor in
                    try? await Task.sleep(for:.seconds(1))
                    guard let window=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).flatMap(\.windows).first(where:\.isKeyWindow) else { return }
                    let image=UIGraphicsImageRenderer(size:window.bounds.size).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
                    let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                    try? image.pngData()?.write(to:directory.appendingPathComponent("\(name).png"))
                    let frame=replayData?.frame(playhead)
                    let report: [String:Any] = ["action":action,"outcome":replayData?.outcome.rawValue ?? "Ready","contact":replayData?.contactTime ?? -1,"time":playhead,"jointCount":boneOrder.count,
                        "netImpacts":frame?.net.count ?? 0,"netDepth":frame?.net.map(\.depth).max() ?? 0,
                        "ball":frame.map { [$0.ball.x,$0.ball.y,$0.ball.z] } ?? []]
                    try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:directory.appendingPathComponent("\(name).json"))
                }
            }
#endif
        } catch { self.error=error.localizedDescription;status="Unable to load keeper" }
        loadTask=nil
    }
    private func findBody(_ entity: Entity) -> ModelEntity? {
        if let m=entity as? ModelEntity,!m.jointNames.isEmpty { return m }
        for child in entity.children { if let m=findBody(child) { return m } };return nil
    }
    func aim(x: Float,y: Float) { settings.x=clamp(x,-5.5,5.5);settings.y=clamp(y,0.11,4.5);reset() }
    func applyPreset(_ name: String) {
        settings.style = .driven
        switch name {
        case "low-left":settings.x = -2.6;settings.y=0.23
        case "low-right":settings.x=2.6;settings.y=0.23
        case "left":settings.x = -2.65;settings.y=1.1
        case "right":settings.x=2.65;settings.y=1.1
        case "top-left":settings.x = -3.25;settings.y=2.25
        case "top-right":settings.x=3.25;settings.y=2.25
        case "low":settings.x=0;settings.y=0.24
        case "high":settings.x=0;settings.y=2.2
        case "panenka":settings.x=0;settings.y=1.1;settings.style = .chip
        case "bounce":settings.x=0.1;settings.y=0.5;settings.style = .bounce
        case "wide":settings.x=4;settings.y=1.1
        case "over":settings.x=0.8;settings.y=3.6
        case "high-wide":settings.x = -4.7;settings.y=3.5
        case "roof":settings.x=1.8;settings.y=2.85;settings.style = .chip
        case "post":settings.x=3.72;settings.y=0.8
        case "crossbar":settings.x=1.8;settings.y=2.5
        default:settings.x=0;settings.y=1.25
        }
        reset()
    }
    func shoot() {
        guard let library else { return }
        demoRunning=false
        let replay=ShotSimulator(library:library).build(settings)
        replayData=replay;duration=replay.duration;playhead=0;hasShot=true;isPlaying=true;action=replay.action
        applyFrame();print("SHOT \(settings.x),\(settings.y) \(settings.style.rawValue) => \(replay.action) \(replay.outcome.rawValue) contact=\(replay.contactTime ?? -1)")
    }
    func reset(clearPhysicalAttempt: Bool=true) {
        demoRunning=false
        reviewActive=false;reviewStage="";reviewResult=nil;reviewCurtain=0
        reviewPlayback=nil;reviewPosesFinalized=false
        if clearPhysicalAttempt { lastPhysicalAttempt=nil;poseHistory=PhysicalPoseHistory() }
        physicalMotion=nil
        physicalTiming=nil;physicalGripStarted=nil
        physicalPreparation=nil
        physicalContactEvidence=[:]
        physicalEntryPose=nil
        replayData=nil;hasShot=false;isPlaying=false;playhead=0;actor?.position = .zero;action="Ready stance";outcome="Aim your shot";status="Drag the target • choose power • shoot"
        target.isEnabled = !physicalBallMode;target.position=[settings.x,settings.y,-0.25]
        if physicalReference || goalChallenge != nil { showPhysicalReference(physicalReference) }
        else { actor?.isEnabled=true;robot?.isEnabled=false }
        ball.isEnabled=false;ball.position=[0,0.11,10.65]
        goalNet?.update(time:0,impacts:[]);updateCamera()
        if let pose=library?.clips["ready"]?.pose(0) { applyPose(pose) }
    }
    func replay() { demoRunning=false;guard replayData != nil else { shoot();return };hasShot=true;playhead=0;isPlaying=true;applyFrame() }
    func togglePlayback() { demoRunning=false;if !hasShot { shoot() } else if playhead>=duration { replay() } else { isPlaying.toggle() } }
    func toggleSpeed() { speed=speed==1 ? 0.25:1 }
    func seek(_ t: Double) { demoRunning=false;guard hasShot else { return };isPlaying=false;playhead=clamp(t,0,duration);applyFrame() }
    func showContact() { if !hasShot { shoot() };seek(replayData?.contactTime ?? replayData?.decisionTime ?? 0) }
    func showNetImpact() {
        if !hasShot { shoot() }
        seek((replayData?.frames.last?.net.first?.start ?? replayData?.decisionTime ?? 0)+0.07)
    }
    func toggleDemo() {
        if demoRunning { demoRunning=false;isPlaying=false }
        else { demoIndex=0;nextDemoShot() }
    }
    private func nextDemoShot() {
        let cases=["centre","low-left","top-right","panenka","roof","over","wide"]
        let name=cases[demoIndex % cases.count];demoIndex += 1
        settings=ShotSettings();settings.power=name == "top-right" ? 1:0.35
        settings.read = .react
        applyPreset(name);shoot();demoRunning=true;demoDelay=0
    }
    private func advance(_ delta: Double) {
        if let size=currentView?.bounds.size,size != viewportSize {
            viewportSize=size
            updateCamera()
            outputRevision += 1
        }
        if physicalBallMode { updateProjectedGoal() }
        if let challenge=goalChallenge {
            let now=CACurrentMediaTime()
            robot?.position=[Float((challenge.blockerCentre(at:now)-0.5)*7.32),
                             Float(challenge.running ? 0.025+0.025*sin(now*2):0),-0.35]
            return
        }
        if reviewActive {
            var now=CACurrentMediaTime()
#if targetEnvironment(simulator)
            if let reviewFrozenAge { now=reviewStarted+reviewFrozenAge }
#endif
            advancePhysicalReview(at:now)
            return
        }
        if physicalMotion != nil {
            advanceLiveKeeper(at:CACurrentMediaTime())
            return
        }
        if hasShot {
            if isPlaying { playhead=min(duration,playhead+min(delta,0.1)*speed);applyFrame();if playhead>=duration { isPlaying=false } }
            else if demoRunning { demoDelay += min(delta,0.1);if demoDelay>=0.8 { nextDemoShot() } }
        } else if let idle=library?.clips["ready"] {
            idleTime += delta
            let now=CACurrentMediaTime()
            if let preparation=physicalPreparation,let library {
                let weight=smooth(Float((now-preparation.started)/0.08))*(1-smooth(Float((now-preparation.updated-0.08)/0.16)))
                applyPose(PhysicalKeeperPreparation.pose(library:library,target:preparation.target,weight:weight,idleTime:idleTime))
                if weight<=0,now-preparation.updated>0.24 { physicalPreparation=nil }
            } else { applyPose(idle.pose(idleTime.truncatingRemainder(dividingBy:idle.duration))) }
            if physicalBallMode {
                poseHistory.append(time:now+physicalDisplayLead,pose:shownPose,offset:actor?.position ?? .zero)
            }
        }
    }
    private func applyPose(_ pose: [BonePose]) {
        shownPose=pose
        body?.jointTransforms=boneOrder.map { i in let p=pose[i];return Transform(scale:p.scale,rotation:p.rotation,translation:p.translation) }
    }
    private func advanceLiveKeeper(at now: Double) {
        guard let library else { return }
        if let motion=physicalMotion {
            let age=physicalTiming?.advance(to:now+physicalDisplayLead) ?? now-physicalMotionStarted+physicalDisplayLead
            let frame=motion.frame(age)
            let entrance=smooth(Float((now-physicalMotionReceived)/0.12))
            var pose=physicalEntryPose.map { zip($0,frame.pose).map { $0.blended(to:$1,fraction:entrance) } } ?? frame.pose
            if reviewResult == .caught,let started=physicalGripStarted {
                pose=PhysicalCatchGrip.apply(library:library,pose:pose,radius:physicalBallRenderRadius,
                    initialRelativeCentre:physicalGripRelativeCentre,time:now-started,
                    remaining:motion.duration-age)
            }
            applyPose(pose)
            actor?.position=physicalEntryOffset+(frame.offset-physicalEntryOffset)*entrance
            if age>=motion.duration { physicalMotion=nil;physicalTiming=nil;action="Ready stance" }
        } else {
            applyPose(library.clips["ready"]!.pose(0));actor?.position = .zero
        }
        poseHistory.append(time:now+physicalDisplayLead,pose:shownPose,offset:actor?.position ?? .zero)
    }
    private func advancePhysicalReview(at now: Double) {
        guard let playback=reviewPlayback,let library,let result=reviewResult else { return }
        let state=playback.state(at:now)
        if reviewCurtain != state.curtain { reviewCurtain=state.curtain }
        switch state.phase {
        case .finish:
            setReviewStage("Result")
            advanceLiveKeeper(at:now)
            playhead=state.time
            applyPhysicalFinishBall(at:now)
        case .emotion:
            setReviewStage("Reaction")
            // Live motion has recovered before this gesture begins.
            physicalMotion=nil
            applyPose(KeeperOutcomeMotion.pose(library:library,result:result,time:state.time,
                                               duration:playback.emotionDuration))
            actor?.position = .zero
            playhead=duration
            applyPhysicalFinishBall(at:now)
            status=result == .goal ? "Goal conceded":([ShotOutcome.caught,.parried,.blocked].contains(result) ? "Save confirmed":"Shot finished")
        case .transition:
            setReviewStage("Transition")
            finalizePhysicalReplay()
        case .replay:
            setReviewStage("Replay");finalizePhysicalReplay()
            playhead=state.time;applyFrame()
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--flow-interrupt"),!flowInterrupted,state.time>0.25 {
                flowInterrupted=true
                let before=shownPose,offset=actor?.position ?? .zero
                let accepted=reactToPhysicalBall(target:[2.3,0.3],lead:0.4,displayLead:0.2)
                let jump=zip(before,shownPose).map { simd_length($0.rotation.vector-$1.rotation.vector) }.max() ?? 0
                auditFlow("interrupted",extra:["accepted":accepted,"reviewActive":reviewActive,
                    "rotationJump":jump,"offsetJump":simd_length(offset-(actor?.position ?? .zero))])
            }
#endif
        case .returning:
            setReviewStage("Returning")
            if state.showReady {
                applyPose(library.clips["ready"]!.pose(0));actor?.position = .zero
                ball.isEnabled=false;goalNet?.update(time:0,impacts:[])
            } else { playhead=duration;applyFrame() }
        case .complete:
            setReviewStage("Ready")
            reset()
        }
    }
    private func setReviewStage(_ stage: String) {
        guard reviewStage != stage else { return }
        reviewStage=stage
#if targetEnvironment(simulator)
        auditFlow(stage)
#endif
    }
#if targetEnvironment(simulator)
    private func auditFlow(_ event: String,extra: [String:Any]=[:]) {
        guard ProcessInfo.processInfo.arguments.contains("--flow-audit") else { return }
        var entry=extra
        entry["event"]=event;entry["age"]=CACurrentMediaTime()-reviewStarted
        entry["playhead"]=playhead;entry["curtain"]=reviewCurtain
        entry["historySamples"]=poseHistory.samples.count
        flowAudit.append(entry)
        let path=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("flow-audit.json")
        if let data=try? JSONSerialization.data(withJSONObject:flowAudit,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:path,options:.atomic)
        }
    }
#endif
    private func finalizePhysicalReplay() {
        guard !reviewPosesFinalized,let replay=replayData,let library else { return }
        replayData=poseHistory.applying(to:replay,origin:reviewOrigin,library:library)
        reviewPosesFinalized=true
    }
    private func applyPhysicalFinishBall(at now: Double) {
        guard let replay=replayData,let library else { return }
        let frame=replay.frame(playhead)
        ball.position=frame.ball;ball.orientation=frame.ballRotation
        ball.isEnabled=true
        if replay.outcome == .caught,!shownPose.isEmpty {
            if let centre=PhysicalCatchGrip.centre(library:library,pose:shownPose,radius:physicalBallRenderRadius),
               physicalMotion != nil {
                ball.position=centre+(actor?.position ?? .zero)
                ball.orientation=replay.frame(replay.contactTime ?? 0).ballRotation
            } else { ball.isEnabled=false }
        }
        if !automaticPhysicalReplay,let flow=reviewPlayback,
           now>flow.confirmedAt+flow.finishDuration-0.22 { ball.isEnabled=false }
        sizePhysicalBall()
        goalNet?.update(time:playhead,impacts:frame.net)
        target.isEnabled=false
    }
    private func applyFrame() {
        guard let replay=replayData else { return }
        let f=replay.frame(playhead);applyPose(f.pose);actor?.position=f.offset;ball.position=f.ball;ball.isEnabled=reviewActive || playhead>=replay.settings.release
        ball.orientation=f.ballRotation
        target.isEnabled=false;outcome=f.outcome.rawValue
        goalNet?.update(time:playhead,impacts:f.net);updateCamera()
        if reviewActive { sizePhysicalBall() } else { ball.scale=SIMD3<Float>(repeating:1) }
        status=reviewActive ? (showingReplay ? "Shot replay · 0.25×":"Virtual result")
            : playhead<replay.settings.release ? "Set position" : "\(replay.action) · \(replay.settings.kmh) km/h"
    }
    private func sizePhysicalBall() {
        // Match the measured wall footprint. During the result the tracker is
        // gated, and the copy clears before tracking resumes for another shot.
        let distance=max(0.1,camera.position.z+0.35)
        let perspective=clamp((camera.position.z-ball.position.z)/distance,0.02,1)
        let scale=physicalBallRenderRadius/0.11*perspective
        // Goal-height adjustment stretches the scene, not the football.
        ball.scale=[scale,scale/max(1,physicalGoalHeight),scale]
    }
    func toggleFraming() { sideView.toggle();updateCamera() }
    private func updateProjectedGoal() {
        guard let view=currentView,view.bounds.width>0,view.bounds.height>0 else { return }
        let opening: [SIMD3<Float>]=[[-3.66,2.44,-0.35],[3.66,2.44,-0.35],[3.66,0,-0.35],[-3.66,0,-0.35]]
        let points=opening.compactMap { point -> CGPoint? in
            guard let p=view.project(worldContent.convert(position:point,to:nil)) else { return nil }
            return CGPoint(x:p.x/view.bounds.width,y:p.y/view.bounds.height)
        }
        guard points.count==4,points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        if projectedGoalCorners.count != 4 || zip(points,projectedGoalCorners).contains(where:{
            hypot($0.x-$1.x,$0.y-$1.y)>0.0001
        }) { projectedGoalCorners=points }
    }
    private func updateCamera() {
        if isProjected {
            camera.camera.fieldOfViewInDegrees=36
            if physicalBallMode {
                // Fit the posts to the actual output, then put the goal line
                // near its lower edge. Room calibration still has to align
                // that edge with the physical floor.
                let aspect=Float(max(1,currentView?.bounds.width ?? 16)/max(1,currentView?.bounds.height ?? 9))
                let width: Float=7.56/clamp(0.90*projectionScale,0.65,0.96)
                let height=max(3.0,width/max(0.5,aspect))
                let distance=height/(2*tan(Float.pi/10))
                let eye=height*0.44
                camera.look(at:[0,eye,-0.35],from:[0,eye,distance-0.35],relativeTo:nil)
            } else {
                camera.look(at:[0,1.1,-0.35],from:[0,1.85,11.8/clamp(projectionScale,0.75,1.15)],relativeTo:nil)
            }
            return
        }
        var focus=SIMD3<Float>(0,1.05,-0.15),widen: Float=0
        let aim=replayData?.settings ?? settings
        if aim.y>2.6 || abs(aim.x)>3.7 {
            focus.x=clamp(aim.x*0.12,-0.8,0.8);focus.y += max(0,aim.y-2.6)*0.25;widen=0.6
        }
        if let replay=replayData {
            let f=replay.frame(playhead)
            if f.outcome == .over || f.outcome == .wide {
                let blend=smooth(Float((playhead-replay.settings.release-replay.settings.flightTime)/0.45))
                let follow=SIMD3<Float>(clamp(f.ball.x*0.18,-1.4,1.4),1.05+clamp((f.ball.y-1.5)*0.25,0,0.9),-0.75)
                focus += (follow-focus)*blend
                widen += (1-widen)*blend
            }
        }
        camera.camera.fieldOfViewInDegrees=(sideView ? 40:36)+widen*7
        camera.look(at:focus,from:sideView ? [6.5,2.6,7.5]:[0,1.85+widen*0.4,9.6+widen],relativeTo:nil)
    }
    private func buildBall() {
        ball.model=ModelComponent(mesh:.generateSphere(radius:0.11),materials:[SimpleMaterial(color:UIColor(white:0.94,alpha:1),roughness:0.6,isMetallic:false)])
        loadBallSkin()
        worldContent.addChild(ball)
        let lime=UnlitMaterial(color:UIColor(red:0.76,green:0.98,blue:0.32,alpha:1))
        for x: Float in [-0.18,0.18] { let tick=ModelEntity(mesh:.generateBox(size:[0.025,0.14,0.015]),materials:[lime]);tick.position.x=x;target.addChild(tick) }
        for y: Float in [-0.18,0.18] { let tick=ModelEntity(mesh:.generateBox(size:[0.14,0.025,0.015]),materials:[lime]);tick.position.y=y;target.addChild(tick) }
        worldContent.addChild(target)
    }
    private func loadBallSkin() {
        ballSkinTask?.cancel()
        let skin=ballSkin
        ballSkinLoading=true;ballSkinError=nil
        ballSkinTask=Task { [weak self] in
            let preparation=Task.detached(priority:.userInitiated) { KeeperBallSkin.prepare(skin) }
            let prepared=await withTaskCancellationHandler {
                await preparation.value
            } onCancel: { preparation.cancel() }
            guard !Task.isCancelled,let self,self.ballSkin==skin else { return }
            defer { self.ballSkinLoading=false }
            guard let prepared else { self.ballSkinError="Couldn’t load \(skin.title).";return }
            do {
                let material=try KeeperBallSkin.material(skin,prepared:prepared)
                let mesh=try KeeperBallSkin.mesh()
                self.ball.model=ModelComponent(mesh:mesh,materials:[material])
                self.ballSpinFrames=prepared.spin
            } catch { self.ballSkinError="Couldn’t load \(skin.title): \(error.localizedDescription)" }
        }
    }
    enum LoadError: LocalizedError { case missing,skeleton;var errorDescription: String? { "The goalkeeper motion library could not be loaded." } }
}

#endif
