#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import UIKit
import Combine

/// Goal presentation with a separate camera inspection step for physical balls.
@MainActor final class VirtualPenaltyPresentation: ObservableObject {
    static let shared=VirtualPenaltyPresentation()
    @Published private(set) var active=false
    @Published var realBallTest=false
    let keeper: KeeperScene
    let physical: RealPenaltySession
    let challenge=GoalChallengeSession()
    private init() {
        let keeper=KeeperScene()
        self.keeper=keeper;physical=RealPenaltySession(keeper:keeper,challenge:challenge)
    }

    func open(realBall: Bool=false,challenge mode: GoalChallengeMode?=nil) {
#if WALL_GAMES_PREVIEW
        guard mode == .topBins else { return }
#endif
        guard !active else { return }
        challenge.select(mode)
        if mode != nil { physical.displayLead=0.25 }
        keeper.setGoalChallenge(mode == nil ? nil:challenge)
        realBallTest=realBall || mode != nil;keeper.setPhysicalBallMode(realBallTest);active=true
        WallTargetsAppDelegate.lock(.landscapeRight)
        UIApplication.shared.isIdleTimerDisabled=true
    }
    func close() { physical.invalidate();active=false;keeper.stop();keeper.setGoalChallenge(nil) }
    var binding: Binding<Bool> { Binding(get:{ self.active },set:{ if !$0 { self.close() } }) }
}

struct VirtualPenaltyCover: ViewModifier {
    var camera: WallTargetsCamera? = nil
    @ObservedObject private var presentation=VirtualPenaltyPresentation.shared
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented:presentation.binding) {
                Group {
                    if presentation.realBallTest, let camera {
                        RealPenaltyCameraView(camera:camera,presentation:presentation,live:presentation.physical,keeper:presentation.keeper)
                    } else if presentation.challenge.mode != nil {
#if targetEnvironment(simulator)
                        GoalChallengePreviewControls(presentation:presentation)
#endif
                    } else {
                        VirtualPenaltiesView(keeper:presentation.keeper,onClose:presentation.close,
                            onRealBall:camera == nil ? nil : { presentation.realBallTest=true })
                    }
                }
                    .interactiveDismissDisabled()
                    .preferredColorScheme(.dark)
            }
            .onChange(of:presentation.realBallTest) { _,physical in
                presentation.physical.invalidate()
                presentation.keeper.setPhysicalBallMode(physical)
            }
            .onChange(of:scenePhase) { _,phase in
                guard presentation.active else { return }
                if phase == .active { presentation.keeper.resumeDisplay() }
                else {
                    presentation.physical.invalidate("Camera paused — calibrate again before starting.")
                    presentation.keeper.suspend()
                }
            }
    }
}

/// Clean output: the phone owns all controls, with a stationary frontal goal on
/// the wall. SwiftUI/RealityKit use the external screen's actual aspect ratio.
struct WallGamesProjectorRoot: View {
    @ObservedObject private var presentation=VirtualPenaltyPresentation.shared
    @ObservedObject private var model=WallTargetsModel.shared
    @ObservedObject private var audit=WallProjectionAudit.shared
#if WALL_GAMES_PREVIEW
    @ObservedObject private var delayTest=WallArcadeDisplayDelay.shared
#endif
    var body: some View {
        if WallThermalStudy.requested { WallThermalStudyView(external: true) }
        else if audit.active { WallProjectionAuditSurface() }
        else if presentation.active {
            VirtualPenaltyProjector(keeper:presentation.keeper)
        } else {
#if WALL_GAMES_PREVIEW
            if model.arcadePresented && model.arcadeSetupGuidePresented && delayTest.presented {
                WallArcadeDelaySurface(test:delayTest).ignoresSafeArea()
            } else if model.arcadePresented && model.arcadeSetupGuidePresented {
                WallArcadeFramingBoard()
            } else if !model.arcadePresented || model.gameScreen == .intro {
                WallArcadeProjectorWelcome()
            } else { WallTargetsBoard(model:model) }
#else
            WallTargetsBoard(model:model)
#endif
        }
    }
}

struct VirtualPenaltyProjector: View {
    @ObservedObject var keeper: KeeperScene
    @ObservedObject private var presentation=VirtualPenaltyPresentation.shared
    @ObservedObject private var physical=VirtualPenaltyPresentation.shared.physical
    @ObservedObject private var challenge=VirtualPenaltyPresentation.shared.challenge
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment:.top) {
                KeeperSurface(keeper:keeper,projected:true)
                Color.black.opacity(keeper.reviewCurtain).allowsHitTesting(false)
                if challenge.mode == nil && presentation.realBallTest && physical.armed && !keeper.reviewActive {
                    PhysicalBallOverlay(live:physical,keeper:keeper)
                }
                if let error=keeper.error {
                    Text(error).foregroundStyle(.white).padding(30).background(.black)
                } else if challenge.mode != nil,physical.armed || challenge.finished {
                    GoalChallengeOverlay(session:challenge,keeper:keeper,size:geometry.size)
                } else if keeper.reviewActive,let result=keeper.reviewResult {
                    PenaltyResultOverlay(result:result,replay:keeper.showingReplay,compact:keeper.reviewStage == "Reaction")
                        .id(keeper.showingReplay)
                } else if presentation.realBallTest && !physical.armed {
                    GuidedPenaltyProjectorOverlay(live:physical,keeper:keeper,size:geometry.size)
                } else {
                    Text(keeper.ready ? (presentation.realBallTest ? (physical.armed ? "REAL BALL · \(keeper.action.uppercased())":"REAL BALL · SETUP") : (keeper.hasShot ? keeper.outcome:"VIRTUAL PENALTIES")):"Loading goalkeeper…")
                        .font(.system(size:geometry.size.height*0.045,weight:.heavy,design:.rounded))
                        .foregroundStyle(.white)
                        .shadow(color:.black,radius:3)
                        .padding(.top,geometry.size.height*0.035)
                }
            }
        }
        .background(.black).ignoresSafeArea()
    }
}
#if targetEnvironment(simulator)
private struct GoalChallengePreviewControls: View {
    @ObservedObject var presentation: VirtualPenaltyPresentation
    @ObservedObject private var challenge=VirtualPenaltyPresentation.shared.challenge
    @ObservedObject private var keeper=VirtualPenaltyPresentation.shared.keeper
    var body: some View {
        VStack(spacing:24) {
            Button("Wall games",action:presentation.close)
            Text(challenge.title).font(.largeTitle.bold())
            Text("Simulator preview · goal on the external display")
            Text("\(challenge.round?.score ?? 0) points · \(challenge.round?.remaining ?? 5) shots left")
            HStack {
                ForEach(GoalChallengeRules.bins) { bin in
                    Button("Target \(bin.id+1)") {
                        let now=CACurrentMediaTime()
                        _=challenge.contact(u:bin.u,v:bin.v,radiusU:0.02,radiusV:0.04,at:now,confirmedAt:now)
                    }
                }
            }
            Button("New round") { presentation.physical.newChallengeRound() }
        }.foregroundStyle(.white).frame(maxWidth:.infinity,maxHeight:.infinity).background(.black)
            .task(id:keeper.ready) {
                guard keeper.ready else { return }
                try? await Task.sleep(for:.milliseconds(600))
                presentation.physical.previewSetup("challenge")
            }
    }
}
#endif
#endif
