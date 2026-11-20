#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import Combine
import QuartzCore

/// Explicit debug-only visual review. It cannot ingest physical shots and uses
/// its own model/defaults, leaving normal gameplay and calibration untouched.
@MainActor final class WallProjectionAudit: ObservableObject {
    struct Step: Identifiable {
        let game: String
        let state: String
        var id: String { game+"-"+state }
    }
    static let shared=WallProjectionAudit()
    static let launchRequested=ProcessInfo.processInfo.arguments.contains("--wall-visual-audit")
    @Published var active=launchRequested
    @Published private(set) var index = -1
    @Published private(set) var model: WallTargetsModel
    @Published private(set) var running=false
    @Published private(set) var complete=false
    @Published private(set) var title="Preparing wall review"
    @Published private(set) var challenge=GoalChallengeSession()
    @Published private(set) var previewTime: Double?
    @Published private(set) var startedAt=0.0
    let keeper=KeeperScene()
    let camera=WallTargetsCamera(onImpact:{ _ in false },onAlignment:{ _ in })
    let feed=WallTargetsLiveFeed(previewWidth:1280)
    let steps: [Step]
    private let defaults: UserDefaults
    private var tour: Task<Void,Never>?
    var current: Step? { steps.indices.contains(index) ? steps[index]:nil }
    var showingGoal: Bool { ["top-bins","find-space","virtual-penalties"].contains(current?.game ?? "") }
    var metadata: [String:Any] {
        ["index":index,"total":steps.count,"game":current?.game ?? "setup","state":current?.state ?? "reference",
         "startedAt":startedAt,"title":title,"running":running,"complete":complete,
         "projectorConnected":WallTargetsModel.shared.projectorConnected,
         "syntheticGameState":true,"physicalScoring":false,
         "keeperReady":keeper.ready,"goalCorners":keeper.projectedGoalCorners.map{[Double($0.x),Double($0.y)]}]
    }
    private init() {
        defaults=UserDefaults(suiteName:"ProjectionAudit.\(UUID().uuidString)")!
        model=WallTargetsModel(defaults:defaults)
        var list=[Step(game:"calibration",state:"reference")]
        for game in WallGame.allCases {
            let states=game == .memoryStrike ? ["watching","playing","impact","lost"] : ["playing","impact","won"]
            list += states.map{Step(game:game.rawValue,state:$0)}
        }
        for game in ["top-bins","find-space","virtual-penalties"] {
            list += ["playing","impact","won"].map{Step(game:game,state:$0)}
        }
        if ProcessInfo.processInfo.arguments.contains("--wall-audit-overview") {
            list=list.filter { $0.state == "playing" || ($0.game == "virtual-penalties" && $0.state == "won") }
        }
        steps=list
        WallAuditScenario(model:model).configure(.clearTheWall,state:"reference")
    }
    func prepare() {
        guard active else { return }
        WallTargetsAppDelegate.lock(.landscapeRight)
        UIApplication.shared.isIdleTimerDisabled=true
        WallPowerMonitor.shared.setContext("projection-visual-audit")
        camera.setScoringEnabled(false);camera.setVisualAuditState(metadata)
        try? feed.start();camera.setLiveFeed(feed);camera.setCaptureResting(false);camera.start()
    }
    func startTour() {
        guard tour == nil,active else { return }
        running=true;complete=false
        tour=Task { @MainActor in
            while !Task.isCancelled,active {
                if running {
                    if index+1>=steps.count {
                        running=false;complete=true;title="Wall review complete";camera.setVisualAuditState(metadata);break
                    }
                    show(index+1)
                    for _ in 0..<80 {
                        do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
                        if !running { break }
                    }
                } else {
                    do { try await Task.sleep(for:.milliseconds(150)) } catch { return }
                }
            }
            tour=nil
        }
    }
    func toggleTour() {
        if tour == nil { if complete { index = -1 };startTour() }
        else { running.toggle();camera.setVisualAuditState(metadata) }
    }
    func step(_ offset: Int) { running=false;show(min(steps.count-1,max(0,index+offset))) }
    private func show(_ next: Int) {
        index=next;complete=false;startedAt=CACurrentMediaTime();previewTime=nil
        let step=steps[next]
        keeper.reset()
        if let game=WallGame(rawValue:step.game) {
            model=WallTargetsModel(defaults:defaults)
            WallAuditScenario(model:model).configure(game,state:step.state)
            title="\(game.title) · \(step.state)"
        } else if step.game == "calibration" {
            model=WallTargetsModel(defaults:defaults)
            WallAuditScenario(model:model).configure(.clearTheWall,state:"reference")
            title="Calibration · hold progress"
        } else {
            title="\(step.game == "virtual-penalties" ? "Virtual Keeper":step.game == "top-bins" ? "Top Bins":"Find the Space") · \(step.state)"
            keeper.setPhysicalBallMode(true)
            challenge=GoalChallengeSession()
            challenge.select(GoalChallengeMode(rawValue:step.game))
            keeper.setGoalChallenge(step.game == "virtual-penalties" ? nil:challenge)
            keeper.showPhysicalReference(false)
            if step.game == "virtual-penalties" {
                if step.state == "impact" { keeper.applyPreset("left");keeper.shoot();keeper.showContact() }
                if step.state == "won" { keeper.applyPreset("top-right");keeper.settings.read = .left;keeper.shoot();keeper.showNetImpact() }
            } else {
                let now=CACurrentMediaTime()
                challenge.goalAspect=keeper.projectedGoalAspect;challenge.displayLead=0.25
                challenge.start(at:now-20)
                if step.state != "playing" {
                    for i in 0..<(step.state == "won" ? 5:1) {
                        let time=step.state == "won" ? now-12+Double(i)*3:now
                        let bin=GoalChallengeRules.bins[i%4]
                        _=challenge.contact(u:bin.u,v:bin.v,radiusU:0.02,radiusV:0.04,at:time,confirmedAt:time)
                    }
                    challenge.pause(at:now)
                    previewTime=now+0.25
                }
            }
        }
        camera.setVisualAuditState(metadata)
    }
    func close() {
        running=false;tour?.cancel();tour=nil;camera.stop();feed.stop();keeper.stop();active=false
    }
}

struct WallProjectionAuditPhone: View {
    @ObservedObject var audit=WallProjectionAudit.shared
    @ObservedObject private var camera=WallProjectionAudit.shared.camera
    @ObservedObject private var wall=WallTargetsModel.shared
    @State private var began=false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        HStack(spacing:20) {
            VStack(alignment:.leading,spacing:16) {
                Text("WALL VISUAL REVIEW").font(.headline).foregroundStyle(.cyan)
                Text(audit.title).font(.title2.bold())
                Text("\(max(0,audit.index+1)) / \(audit.steps.count)").monospacedDigit()
                Text("Camera watches the real projection. Game states are demonstration states; no physical shots are scored.").font(.callout)
                Text(wall.projectorConnected ? "Projector connected":"Waiting for projector").foregroundStyle(wall.projectorConnected ? .green:.orange)
                HStack {
                    Button("Previous") { audit.step(-1) }
                    Button(audit.running ? "Pause":"Continue",action:audit.toggleTour)
                    Button("Next") { audit.step(1) }
                }.buttonStyle(.bordered)
                Button("Finish review",action:audit.close).buttonStyle(.borderedProminent)
                WallTargetsRuntimeHUD(sample:camera.runtime)
            }.frame(width:300)
            WallTargetsPreview(session:camera.session).clipped()
        }.padding(24).background(.black).foregroundStyle(.white)
            .statusBarHidden().persistentSystemOverlays(.hidden)
            .onAppear(perform:audit.prepare)
            .task(id:"\(camera.isReady)-\(wall.projectorConnected)") {
                guard camera.isReady,wall.projectorConnected,!began else { return }
                began=true
                do { try await Task.sleep(for:.seconds(4)) } catch { return }
                await camera.lockVisualAuditCamera()
                audit.startTour()
            }
            .onChange(of:scenePhase) { _,phase in if phase != .active { audit.runningPause() } }
    }
}

extension WallProjectionAudit {
    func runningPause() { if running { toggleTour() } }
}

struct WallProjectionAuditSurface: View {
    @ObservedObject var audit=WallProjectionAudit.shared
    @ObservedObject private var keeper=WallProjectionAudit.shared.keeper
    var body: some View {
        GeometryReader { geo in
            if audit.showingGoal {
                ZStack(alignment:.top) {
                    KeeperSurface(keeper:keeper,projected:true)
                    if audit.current?.game == "virtual-penalties" {
                        if audit.current?.state == "won" { PenaltyResultOverlay(result:.goal,replay:false,compact:true) }
                        else { Text(audit.current?.state == "impact" ? "SAVE":"VIRTUAL PENALTIES")
                            .font(.system(size:geo.size.height*0.045,weight:.heavy,design:.rounded))
                            .foregroundStyle(.white).padding(.top,geo.size.height*0.035) }
                    } else {
                        GoalChallengeOverlay(session:audit.challenge,keeper:keeper,size:geo.size,previewTime:audit.previewTime)
                    }
                }
            } else {
                WallTargetsBoard(model:audit.model).id(audit.index)
                    .overlay(alignment:.topLeading) {
                        if audit.model.game == .brickBlast,audit.current?.state == "impact",let hit=audit.model.lastHit {
                            let rect=WallTargetsBoard.boardRect(in:geo.size)
                            let local=CGRect(origin:.zero,size:rect.size)
                            let bricks=hit.brickDamage.compactMap { damage -> WallBrickExplosion.Brick? in
                                guard let target=audit.model.game.layout.target(damage.id) else { return nil }
                                return .init(id:damage.id,frame:target.screenFrame(in:local),shattered:damage.shattered)
                            }
                            let footprintArea=CGFloat(abs(hit.footprint?.determinant ?? 0))
                            let radius: CGFloat=sqrt(footprintArea * rect.width * rect.height / 6)
                            WallBrickExplosion(bricks:bricks,origin:CGPoint(x:hit.u/3*rect.width,y:hit.v/2*rect.height),
                                ballRadius:radius,strength:WallImpactMotion.strength(for:hit.approachSpeed),previewAge:0.32)
                                .frame(width:rect.width,height:rect.height).clipped().offset(x:rect.minX,y:rect.minY)
                        }
                    }
            }
        }.background(.black).ignoresSafeArea()
    }
}
#endif
