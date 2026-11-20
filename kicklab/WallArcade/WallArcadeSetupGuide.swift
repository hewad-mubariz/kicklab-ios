#if WALL_GAMES_PREVIEW
import AVFoundation
import SwiftUI

/// This preflight never certifies calibration. The game's live corner, mapping
/// and ball-depth checks still decide whether it is safe to start scoring.
struct WallArcadeSetupGuide: View {
    @ObservedObject var model: WallTargetsModel
    @ObservedObject var camera: WallTargetsCamera
    var returnsToGame = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var step = 0
    @State private var preview = false
    @State private var showsDelayTest = false
    @State private var displayChangedDuringTest = false
    @ObservedObject private var delayTest = WallArcadeDisplayDelay.shared
    private let steps = ["Connect", "Frame the wall", "Play"]

    var body: some View {
        NavigationStack {
            Group {
            if showsDelayTest {
                WallArcadeDelayControls(test:delayTest,camera:camera,separateDisplay:model.projectorConnected)
                    .safeAreaInset(edge:.bottom) {
                        if displayChangedDuringTest {
                            Text("Display changed. Tap to start a fresh test.")
                                .font(.caption.bold()).foregroundStyle(.orange).padding(8)
                        }
                    }
            } else {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        HStack(spacing:8) {
                            ForEach(0..<3) { index in
                                Button { changeStep(index) } label: {
                                    HStack(spacing:7) {
                                        Text("\(index+1)").font(.caption.bold())
                                            .frame(width:24,height:24)
                                            .background(step == index ? WallArcadeStyle.lime:.white.opacity(0.12),in:.circle)
                                            .foregroundStyle(step == index ? Color.black:.white)
                                        Text(steps[index]).font(.caption.bold()).foregroundStyle(step == index ? .white:.white.opacity(0.5))
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                }.buttonStyle(.plain).accessibilityIdentifier("arcade-setup-step-\(index)")
                            }
                        }
                        if geo.size.width >= 650 && !typeSize.isAccessibilitySize {
                            HStack(alignment:.top,spacing:24) {
                                visual.frame(width:(geo.size.width-68)*0.46)
                                instructions.frame(width:(geo.size.width-68)*0.54,alignment:.leading)
                            }
                        } else { VStack(alignment:.leading,spacing:20) { visual;instructions } }
                    }.padding(.horizontal,22).padding(.vertical,12)
                }
                .safeAreaInset(edge:.bottom,spacing:0) {
                    HStack {
                        if step>0 { Button("Back") { changeStep(step-1) }.buttonStyle(.glass).tint(.white) }
                        Spacer()
                        Button(step == 0 ? "Check camera":step == 1 ? "Next":returnsToGame ? "Back to game":"Back to games") {
                            if step<2 { changeStep(step+1) } else { dismiss() }
                        }.buttonStyle(.glassProminent).tint(WallArcadeStyle.lime).foregroundStyle(TrainingHomeStyle.buttonInk)
                            .accessibilityIdentifier("arcade-setup-next")
                    }.padding(.horizontal,22).padding(.vertical,10).background(WallArcadeStyle.background)
                }
            }
            }
            }
            .background(WallArcadeStyle.background).foregroundStyle(.white)
            .navigationTitle(showsDelayTest ? "Display delay test":"Set up your wall").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    if showsDelayTest {
                        Button("Back to setup",systemImage:"chevron.left") { closeDelayTest() }
                            .accessibilityIdentifier("arcade-delay-back")
                    }
                }
                ToolbarItem(placement:.topBarTrailing) {
                Button("Close setup guide",systemImage:"xmark") { dismiss() }
                    .labelStyle(.iconOnly).accessibilityIdentifier("arcade-guide-close")
            } }
        }.preferredColorScheme(.dark).tint(WallArcadeStyle.lime)
            .onAppear {
                model.arcadeSetupGuidePresented=true
                WallTargetsAppDelegate.lock(.landscapeRight)
            }
            .onChange(of:preview) { _,enabled in camera.setFramingPreview(enabled) }
            .onChange(of:scenePhase) { _,phase in if phase != .active { preview=false;delayTest.stop() } }
            .onChange(of:model.projectorConnected) { _,_ in
                preview=false
                if showsDelayTest { delayTest.stop();displayChangedDuringTest=true }
            }
            .onChange(of:delayTest.running) { _,running in if running { displayChangedDuringTest=false } }
            .onDisappear { delayTest.close();camera.setFramingPreview(false) }
    }

    private func changeStep(_ next:Int) { preview=false;step=next }
    private func openDelayTest() {
        preview=false
        camera.setFramingPreview(false)
        displayChangedDuringTest=false
        delayTest.open()
        showsDelayTest=true
    }
    private func closeDelayTest() { delayTest.close();showsDelayTest=false }

    @ViewBuilder private var visual: some View {
        if step == 1 {
            VStack(spacing:10) {
                if preview {
                    WallArcadeCameraView(camera:camera).aspectRatio(16/9,contentMode:.fit).frame(maxHeight:170)
                        .overlay(alignment:.bottomTrailing) {
                            Button("Hide camera",systemImage:"eye.slash") { preview=false }
                                .labelStyle(.iconOnly).buttonStyle(.glass).tint(.white).padding(10)
                                .accessibilityIdentifier("arcade-hide-camera")
                        }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius:18).fill(WallArcadeStyle.panel)
                        VStack(spacing:12) {
                            Image(systemName:"camera.viewfinder").font(.system(size:40)).foregroundStyle(WallArcadeStyle.lime)
                            Text("See what your phone sees").font(.headline)
                            Button("View camera") { preview=true }
                                .buttonStyle(.glassProminent).tint(WallArcadeStyle.lime).foregroundStyle(TrainingHomeStyle.buttonInk)
                                .accessibilityIdentifier("arcade-view-camera")
                        }.padding(16)
                    }.aspectRatio(16/9,contentMode:.fit).frame(maxHeight:170)
                }
                Text("Framing preview only · the game checks alignment next")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        } else {
            WallArcadeDisplayDiagram(ready:step == 2)
        }
    }

    @ViewBuilder private var instructions: some View {
        VStack(alignment:.leading,spacing:13) {
            if step == 0 {
                Text("PHONE FOR SETUP.\nWALL FOR PLAY.").font(WallArcadeStyle.display(32))
                Label(model.projectorConnected ? "Separate display connected":"No separate display detected",
                      systemImage:model.projectorConnected ? "checkmark.rectangle.stack":"rectangle.on.rectangle.slash")
                    .font(.subheadline.bold()).foregroundStyle(model.projectorConnected ? WallArcadeStyle.lime:.orange)
                    .accessibilityIdentifier("arcade-display-status")
                Text(model.projectorConnected
                     ? "Your wall shows four white dots. Camera views, buttons and replays stay on this phone."
                     : "Connect the projector by HDMI, or use Screen Mirroring in Control Centre. Keep this app open.")
                if !model.projectorConnected {
                    Text("Wall copies this screen? That's mirroring. The phone will show the game too.")
                        .foregroundStyle(.white.opacity(0.65))
                } else {
                    Text("A cable gives the quickest feedback.").foregroundStyle(.white.opacity(0.65))
                }
                Button("Test display delay",systemImage:"timer") { openDelayTest() }
                    .buttonStyle(.glass).tint(.white).accessibilityIdentifier("arcade-open-delay-test")
            } else if step == 1 {
                Text("FIT THE WHOLE WALL.").font(WallArcadeStyle.display(32))
                Text(model.projectorConnected
                     ? "Mount the phone sideways. Fit all four dots, with space around them, inside the rear camera view."
                     : "Mount the phone sideways. Frame the entire projected picture with space around it. The game checks the four dots next.")
                Text("Keep both devices outside the rebound path. Light the ball and leave the corners clear.")
                    .foregroundStyle(.white.opacity(0.7))
                if !model.projectorConnected {
                    Label("Mirroring shows this preview on the wall too. Hide it before playing.",systemImage:"rectangle.on.rectangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("ONE HOLD.\nTHEN PLAY.").font(WallArcadeStyle.display(32))
                Text("Choose a game. Stand aside while it finds the wall, then hold the ball against the centre mark until the ring fills.")
                Text("Keep the same ball, phone and projector in place. Other wall games can reuse the hold after a fresh alignment check. Top Bins sets up its goal separately.")
                    .foregroundStyle(.white.opacity(0.7))
                if model.hasReusableSetup {
                    Label("A previous ball hold is available",systemImage:"checkmark.circle").foregroundStyle(WallArcadeStyle.lime)
                    Button("I moved the setup / changed the ball") { model.invalidateCalibration() }
                        .font(.caption.bold()).buttonStyle(.glass).tint(.white)
                        .accessibilityIdentifier("arcade-reset-setup")
                }
                Text("Leaving the arcade or interrupting the camera requires setup again.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }
        }.font(.subheadline).fixedSize(horizontal:false,vertical:true)
    }
}

/// A layout illustration, not a simulated camera image or a readiness indicator.
private struct WallArcadeDisplayDiagram: View {
    let ready:Bool
    var body:some View {
        VStack(spacing:12) {
            ZStack {
                RoundedRectangle(cornerRadius:12).fill(.black)
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(.white.opacity(0.3),lineWidth:2))
                VStack(spacing:4) {
                    Image(systemName:ready ? "soccerball":"viewfinder").font(.system(size:30)).foregroundStyle(WallArcadeStyle.lime)
                    Text(ready ? "THE GAME":"YOUR WALL").font(WallArcadeStyle.display(20))
                }.padding(15)
            }.aspectRatio(3,contentMode:.fit)
                .overlay { VStack { HStack { dot;Spacer();dot };Spacer();HStack { dot;Spacer();dot } }.padding(12) }
            HStack(spacing:16) {
                Image(systemName:"iphone.gen3.radiowaves.left.and.right").font(.system(size:30))
                VStack(alignment:.leading,spacing:4) {
                    Text("YOUR PHONE").font(.caption.bold()).foregroundStyle(WallArcadeStyle.lime)
                    Text(ready ? "Controls, results & replays":"Camera view & setup").font(.subheadline)
                }
                Spacer(minLength:0)
            }
        }.padding(14).background(WallArcadeStyle.panel,in:.rect(cornerRadius:18))
    }
    private var dot:some View { Circle().fill(.white).frame(width:7,height:7) }
}

/// Native capture-layer preview: aspect fit, no crop/zoom, matching the landscape
/// sensor coordinates used by hit detection. It does not render a second game.
struct WallArcadeCameraView: View {
    @ObservedObject var camera:WallTargetsCamera
    var body:some View {
        ZStack {
            Color.black
            if camera.isReady {
                WallTargetsPreview(session:camera.session)
                VStack { HStack { Label("REAR CAMERA",systemImage:"camera.fill").font(.caption2.bold()).padding(8).background(.black.opacity(0.75),in:.capsule);Spacer() };Spacer() }.padding(10)
            } else {
                VStack(spacing:10) {
                    Image(systemName:"camera").font(.largeTitle).foregroundStyle(WallArcadeStyle.lime)
#if targetEnvironment(simulator)
                    Text("Live camera is available on iPhone").font(.headline)
                    Text("The simulator cannot show your room.").font(.caption).foregroundStyle(.secondary)
#else
                    Text(camera.status).font(.subheadline).multilineTextAlignment(.center)
                    if AVCaptureDevice.authorizationStatus(for:.video) == .denied {
                        Button("Open Settings") {
                            if let url=URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.glass).tint(.white)
                    }
#endif
                }.padding(16)
            }
        }.foregroundStyle(.white).clipShape(.rect(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.2)))
            .accessibilityIdentifier("arcade-camera-preview")
    }
}

/// Exact same marker centres as the game. No calibration state is created here.
struct WallArcadeFramingBoard: View {
    var body:some View {
        GeometryReader { geo in
            let rect=WallTargetsBoard.boardRect(in:geo.size)
            let dot=geo.size.height*0.032
            ZStack {
                Color.black
                Rectangle().stroke(.white.opacity(0.15),lineWidth:1)
                    .frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY)
                VStack(spacing:geo.size.height*0.035) {
                    Text("FRAME YOUR WALL").font(WallArcadeStyle.display(geo.size.height*0.075))
                    Text("Keep all four dots inside the phone camera")
                        .font(.system(size:geo.size.height*0.036,weight:.semibold))
                    Text("Continue setup on your phone").font(.system(size:geo.size.height*0.03)).foregroundStyle(.white.opacity(0.65))
                }.position(x:rect.midX,y:rect.midY)
                ForEach([CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),
                         CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)],id:\.debugDescription) { point in
                    Circle().fill(.white).frame(width:dot,height:dot)
                        .padding(dot/2).background(.black,in:.circle).position(point)
                }
            }
        }.background(.black).foregroundStyle(.white).ignoresSafeArea()
            .accessibilityIdentifier("arcade-projector-framing")
    }
}
#endif
