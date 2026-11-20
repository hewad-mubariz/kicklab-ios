#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import QuartzCore
import SwiftUI

/// Physical input setup and reaction trial. Save scoring is deliberately
/// separate from predicting an approaching ball and moving the keeper.
struct RealPenaltyCameraView: View {
    @ObservedObject var camera: WallTargetsCamera
    @ObservedObject var presentation: VirtualPenaltyPresentation
    @ObservedObject var live: RealPenaltySession
    @ObservedObject var keeper: KeeperScene
    @ObservedObject private var challenge=VirtualPenaltyPresentation.shared.challenge
    @ObservedObject private var wall=WallTargetsModel.shared
    @State private var recordingTask: Task<Void,Never>?
    @State private var testMessage="Record a short test for ball tracking."
    @State private var searchingCamera=false
#if WALL_GAMES_PREVIEW
    @State private var productRecording=false
    @State private var productSaving=false
    @State private var productEnded=false
    @State private var productSavedFolder: URL?
    @State private var productFinishTask: Task<Void,Never>?
    @State private var productReplay=false
    @State private var latestChallenge: [String:Any]=[:]
    @State private var latestActiveSeconds=0.0
#endif
#if WALL_GAMES_PREVIEW
    private let lime=TrainingHomeStyle.lime
#else
    private let lime=Color(red:0.76,green:0.98,blue:0.32)
#endif

    private var cameraContent: some View {
        HStack(spacing:18) {
            ScrollView {
              VStack(alignment:.leading,spacing:10) {
#if WALL_GAMES_PREVIEW
                productControls
#else
                Button(action:presentation.close) { Label("Wall games",systemImage:"chevron.left") }
                Text(challenge.mode?.title ?? "Real penalties").font(.system(size:20,weight:.bold))
                Text(wall.projectorConnected ? "Goal on projector\nCamera on this phone" : "Connect the projector for the goal.")
                    .font(.system(size:12,weight:.semibold)).foregroundStyle(lime)
                if live.phase == .inspect {
                    HStack {
                        Text("Goal height")
                        Slider(value:$keeper.physicalGoalHeight,in:1...1.5).accessibilityLabel("Goal height")
                        Text("\(Int(keeper.physicalGoalHeight*100))%").monospacedDigit()
                    }
                }
                PenaltySetupSteps(live:live)
                setupControls
                if let mode=challenge.mode {
                    Text(mode.instruction).font(.callout.bold()).foregroundStyle(lime)
                    if let round=challenge.round {
                        Text("\(round.score) points · \(round.remaining) shots left").font(.title3.bold())
                        if round.finished {
                            Button("New five-shot round",action:live.newChallengeRound)
                                .buttonStyle(.borderedProminent).foregroundStyle(.black)
                        }
                    }
                }
                if !live.settingUp {
                    if challenge.mode == nil {
                    Toggle("Follow my real ball",isOn:$live.showTrackedBall)
                    HStack {
                        BallSkinPreview(skin:keeper.ballSkin).frame(width:36,height:36)
                        Picker("Ball",selection:$keeper.ballSkin) {
                            ForEach(KeeperBallSkin.choices) { skin in Text(skin.title).tag(skin) }
                        }.pickerStyle(.menu).disabled(keeper.ballSkinLoading)
                        if keeper.ballSkinLoading { ProgressView().controlSize(.small) }
                    }
                    if let message=keeper.ballSkinError { Text(message).foregroundStyle(.orange).font(.caption2) }
                    }
                    HStack {
                        Text(challenge.mode == nil ? "Projector lead":"Display delay")
                        Slider(value:$live.displayLead,in:0...0.25,step:0.025)
                            .disabled(challenge.mode != nil && live.armed)
                            .accessibilityLabel("Projector timing lead")
                        Text("\(Int(live.displayLead*1000)) ms").monospacedDigit()
                    }
                    Text(challenge.mode == nil ? "Raise if the copy lags; lower if it jumps ahead. Short or lost tracks may show no copy." : "Uses the opening visible when your ball hit. Pause before adjusting; keep 250 ms for the wireless test.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(challenge.mode == nil ? "Real-ball shots · one live save attempt. Keep the phone and projector still after calibration." : "Shoot the real ball. One confirmed wall contact counts as one shot. Keep the phone and projector still.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(recordingTask == nil ? "Record 20-second test" : "Stop & save") {
                    if let recordingTask { recordingTask.cancel() }
                    else { recordTest() }
                }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .disabled(!camera.isReady || camera.recordingState == .saving || (live.settingUp && recordingTask == nil))
                Text(testMessage).font(.caption2).foregroundStyle(.secondary)
                Text(camera.isReady ? String(format:"Detection %.0f fps · %.0f ms",camera.processingFPS,camera.detectorMS) : camera.status)
                    .font(.system(size:11,design:.monospaced))
                WallTargetsRuntimeHUD(sample: camera.runtime)
                if challenge.mode == nil {
                    Button("Simulated trial") { presentation.realBallTest=false }.font(.callout)
                }
#endif
              }.font(.system(size:12)).padding(.vertical,12)
            }.frame(width:270)
            GeometryReader { g in
                let video=AVMakeRect(aspectRatio:camera.frameSize,insideRect:CGRect(origin:.zero,size:g.size))
                ZStack(alignment:.bottomLeading) {
                    WallTargetsPreview(session:camera.session)
                    Canvas { context,_ in
                        let points=live.corners.map { CGPoint(x:video.minX+$0.x*video.width,y:video.minY+$0.y*video.height) }
                        var path=Path()
                        for (i,p) in points.enumerated() {
                            if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
                            context.fill(Path(ellipseIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)),with:.color(lime))
                            context.draw(Text("\(i+1)").font(.caption.bold()).foregroundStyle(.black),at:p)
                        }
                        if points.count == 4 { path.closeSubpath() }
                        context.stroke(path,with:.color(lime),lineWidth:2)
                        if let p=live.predictedPoint {
                            let at=CGPoint(x:video.minX+p.x*video.width,y:video.minY+p.y*video.height)
                            context.stroke(Path(ellipseIn:CGRect(x:at.x-10,y:at.y-10,width:20,height:20)),with:.color(.pink),lineWidth:3)
                        }
                    }.allowsHitTesting(false)
                    if live.phase == .reference {
                        ForEach(Array(live.cameraTargets.enumerated()),id:\.offset) { index,point in
                            if index<=live.completedHolds.count {
                                let complete=index<live.completedHolds.count
                                let diameter: CGFloat=complete ? 24:48
                                PenaltySetupRing(number:index+1,progress:complete ? 1:live.referenceProgress,complete:complete)
                                    .frame(width:diameter,height:diameter)
                                    .position(x:video.minX+point.x*video.width,y:video.minY+point.y*video.height)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    if let ball=camera.ball {
                        Circle().stroke(.yellow,lineWidth:3)
                            .frame(width:max(12,ball.width*video.width),height:max(12,ball.width*video.width))
                            .position(x:video.minX+ball.x*video.width,y:video.minY+ball.y*video.height)
                    }
                    Text(live.settingUp ? live.setupTitle : camera.ball == nil ? "Waiting for a real ball" : "Ball detected")
                        .font(.caption.bold()).padding(10).background(.black.opacity(0.7),in:Capsule()).padding(12)
                }.clipped().contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard video.contains(tap.location) else { return }
                        live.addCorner(CGPoint(x:(tap.location.x-video.minX)/video.width,y:(tap.location.y-video.minY)/video.height))
                    })
            }
        }
        .padding(.horizontal,20)
        .background(.black).foregroundStyle(.white).tint(lime)
        .statusBarHidden().persistentSystemOverlays(.hidden)
    }

    var body: some View {
        cameraContent
        .onDisappear {
#if WALL_GAMES_PREVIEW
            finishProductRound(reason:"view_closed")
#endif
            recordingTask?.cancel();camera.setPhysicalReferenceCorners([]);live.invalidate()
        }
#if WALL_GAMES_PREVIEW
        .sheet(isPresented:$productReplay) {
            if let folder=productSavedFolder, let record=WallArcadeRecord(folder:folder) {
                NavigationStack { WallArcadeReplay(record:record).toolbar { ToolbarItem(placement:.topBarTrailing) {
                    Button("Close replay",systemImage:"xmark") { productReplay=false }.labelStyle(.iconOnly)
                } } }
            }
        }
        .onChange(of:challenge.round?.shots.count) { _,_ in
            if productRecording { latestChallenge=challenge.snapshot; latestActiveSeconds=challenge.activeSeconds }
        }
        .onChange(of:challenge.finished) { _,finished in
            if finished { finishProductRound(reason:"round_complete") }
        }
        .onChange(of:camera.runtime.shouldEndRound) { _,end in
            if end { finishProductRound(reason:"thermal_critical") }
        }
        .onChange(of:live.phase) { _,phase in
            if [.finding,.focusing,.reference,.countdown,.playing].contains(phase) { beginProductRecording() }
            if phase == .playing { camera.markPlaying() }
            if phase == .inspect && productRecording { finishProductRound(reason:"setup_invalidated",useLatest:true) }
        }
#endif
        .onChange(of:keeper.outputRevision) { _,_ in live.invalidate("Goal shape changed — calibrate its corners again.") }
        .onChange(of:wall.projectorConnected) { _,_ in live.invalidate("Display changed — calibrate the goal again.") }
        .onChange(of:camera.frameSize) { _,_ in live.invalidate("Camera framing changed — calibrate again.") }
        .onChange(of:camera.isReady) { _,ready in if !ready { live.invalidate("Camera paused — calibrate again.") } }
        .onChange(of:camera.frameSize,initial:true) { _,size in
            live.imageAspect=Double(max(1,size.width)/max(1,size.height))
            live.imageWidth=Double(max(1,size.width))
        }
        .task(id:live.phase) {
            camera.setPhysicalReferenceCorners([.focusing,.reference].contains(live.phase) ? live.corners:[],
                                               ballGate:live.referenceBallGate)
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains(where:{$0.hasPrefix("--penalty-setup-preview=")}) { return }
#endif
            if live.phase == .finding {
                await findGoal()
            } else if live.phase == .focusing {
                let focused=await camera.acquireFocus(near:live.corners)
                guard !Task.isCancelled else { return }
                live.referenceFocusFinished(focused)
            } else if live.phase == .countdown {
                for number in (1...5).reversed() {
                    guard !Task.isCancelled else { return }
                    live.countDown(number)
                    do { try await Task.sleep(for:.seconds(1)) } catch { return }
                }
                guard !Task.isCancelled,camera.isReady,wall.projectorConnected else { return }
                live.start()
            }
        }
#if targetEnvironment(simulator)
        .task(id:keeper.ready) {
            guard keeper.ready,let arg=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--penalty-setup-preview=")}) else { return }
            do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
            live.previewSetup(String(arg.dropFirst("--penalty-setup-preview=".count)))
        }
#endif
    }

#if WALL_GAMES_PREVIEW
    @ViewBuilder private var productControls: some View {
        Button { finishProductRound(reason:"games",close:true) } label: {
            Image(systemName:"chevron.left").font(.system(size:18,weight:.medium)).frame(width:32,height:32)
        }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).tint(.white)
            .disabled(productSaving).accessibilityLabel("Back to all games").accessibilityIdentifier("top-bins-close")
        Text("TOP BINS").font(WallArcadeStyle.display(40))
        Text("Five shots. Make them count.").font(.subheadline).foregroundStyle(.secondary)
        if productEnded { productResultControls } else { productSetupControls }
        if live.phase == .inspect,productSavedFolder != nil {
            Button("Set up goal again") { productSavedFolder=nil;productEnded=false;camera.setCaptureResting(false);live.beginCalibration() }
                .buttonStyle(.glass).tint(.white).disabled(productSaving || !camera.isReady || !wall.projectorConnected || !camera.runtime.canStartRound)
        }
        if let notice=camera.runtime.startNotice { Text(notice).font(.caption.bold()).foregroundStyle(.orange) }
    }

    @ViewBuilder private var productResultControls: some View {
            Text("\(latestChallenge["score"] as? Int ?? 0)").font(WallArcadeStyle.display(72)).foregroundStyle(lime)
            Text("POINTS · \((latestChallenge["shots"] as? [[String:Any]])?.count ?? 0) OF 5 SHOTS").font(.caption.bold())
            Text(productSaving ? "Saving your round…":productSavedFolder != nil ? "Round saved on this iPhone":"No replay saved")
                .font(.caption).foregroundStyle(.secondary)
            Button("Play again") {
                camera.setCaptureResting(false)
                productSavedFolder=nil;productEnded=false
                if live.phase == .inspect { live.beginCalibration() } else { live.prepareChallengeRound() }
            }.buttonStyle(.glassProminent)
                .foregroundStyle(productSaving || !camera.runtime.canStartRound || !wall.projectorConnected ? Color.white : TrainingHomeStyle.buttonInk)
                .disabled(productSaving || !camera.runtime.canStartRound || !wall.projectorConnected)
            Button { productReplay=true } label: { Label("Replay & share",systemImage:"play.rectangle") }
                .buttonStyle(.glass).tint(.white).disabled(productSavedFolder==nil || productSaving)
    }
    @ViewBuilder private var productSetupControls: some View {
            Text(wall.projectorConnected ? "Goal on projector · camera on phone":"Connect your projector to show the goal.")
                .font(.caption.bold()).foregroundStyle(lime)
            if live.phase == .inspect {
                HStack { Text("Goal height");Slider(value:$keeper.physicalGoalHeight,in:1...1.5).accessibilityLabel("Goal height") }
            }
            PenaltySetupSteps(live:live)
            if live.phase == .inspect {
                Button("Set up goal") { camera.setCaptureResting(false);live.beginCalibration() }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(!camera.isReady || !wall.projectorConnected || !keeper.ready || productSaving || !camera.runtime.canStartRound ? Color.white : TrainingHomeStyle.buttonInk)
                    .disabled(!camera.isReady || !wall.projectorConnected || !keeper.ready || productSaving || !camera.runtime.canStartRound)
                    .accessibilityIdentifier("top-bins-setup")
            } else if live.phase == .ready {
                Button("Continue round") { camera.setCaptureResting(false);live.start() }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(productSaving || !camera.runtime.canStartRound ? Color.white : TrainingHomeStyle.buttonInk)
                    .disabled(productSaving || !camera.runtime.canStartRound)
            }
            if live.armed {
                Text("\(challenge.round?.score ?? 0) points · \(challenge.round?.remaining ?? 5) shots left").font(.title3.bold()).foregroundStyle(lime)
            }
            if productRecording {
                Button { finishProductRound(reason:"stop_button") } label: { Label("Stop & save",systemImage:"stop.circle") }.buttonStyle(.glass).tint(.white)
            }
            Text("Upper rings 100 · lower rings 50. Keep the phone and projector fixed.").font(.caption).foregroundStyle(.secondary)
    }

    private func beginProductRecording() {
        guard !productRecording,!productSaving,!productEnded,camera.isReady else { return }
        productSavedFolder=nil;productRecording=true
        latestChallenge=challenge.snapshot;latestActiveSeconds=0
        camera.startRecording(extra:["game":"top-bins","gameTitle":"Top Bins","mode":"top-bins",
            "app":"Juggle Dude Play","challenge":challenge.snapshot,"keeper":live.telemetry.json])
    }
    private func finishProductRound(reason:String,close:Bool=false,useLatest:Bool=false) {
        guard productRecording else { if close && !productSaving { presentation.close() };return }
        productRecording=false;productSaving=true;productEnded=true
        let snapshot=useLatest ? latestChallenge:challenge.snapshot
        let seconds=useLatest ? latestActiveSeconds:challenge.activeSeconds
        latestChallenge=snapshot;latestActiveSeconds=seconds
        if live.settingUp { live.invalidate() } else { live.pause() }
        let metadata:[String:Any]=["game":"top-bins","stopReason":reason,"challengeEnd":snapshot,
            "activePlaySeconds":seconds,"keeperEnd":live.telemetry.json]
        camera.updateRecordingMetadata(metadata)
        productFinishTask=Task { @MainActor in
            if reason == "round_complete" { try? await Task.sleep(for:.seconds(2)) }
            await camera.stopRecording(extra:metadata)
            camera.setCaptureResting(true)
            productSavedFolder=camera.recordingState == .saved ? camera.lastRecording:nil
            productSaving=false;productFinishTask=nil
            if close { presentation.close() }
        }
    }
#endif

    @ViewBuilder private var setupControls: some View {
        if live.settingUp {
            HStack {
                Button("Cancel setup") { live.invalidate() }.buttonStyle(.bordered)
                if live.phase == .countdown { Button("Wait",action:live.pause).buttonStyle(.bordered) }
            }
        } else {
            if live.phase == .ready {
                Button(challenge.mode == nil ? "Start reactions":"Start round",action:live.start).buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
            if live.armed && !challenge.finished { Button("Pause",action:live.pause).buttonStyle(.bordered) }
            Button(live.phase == .inspect ? "Start guided setup":"Set up again",action:live.beginCalibration)
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
                .disabled(!camera.isReady || !wall.projectorConnected || !keeper.ready || searchingCamera || keeper.projectedGoalCorners.count != 4)
            if live.canUseManualCorners {
                Button("Mark corners on phone instead",action:live.beginManualCalibration)
                    .disabled(searchingCamera || !camera.isReady || !wall.projectorConnected)
            }
        }
    }

    private func findGoal() async {
        guard !searchingCamera else { return }
        searchingCamera=true
        defer { searchingCamera=false }
        // Same blink search and display-latency allowance as the wall games.
        guard await camera.acquireFocus(),!Task.isCancelled else {
            if !Task.isCancelled { live.foundGoal(nil) }
            return
        }
        for number in (1...3).reversed() {
            live.prepareSearch(number)
            do { try await Task.sleep(for:.seconds(1)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        live.prepareSearch(nil)
        await camera.beginCornerSearch()
        var on: [ClosedRange<Double>]=[],off: [ClosedRange<Double>]=[]
        for phase in 0..<4 {
            live.showSearchDots(!phase.isMultiple(of:2))
            let start=CACurrentMediaTime()
            do { try await Task.sleep(for:.milliseconds(1200)) }
            catch { _=await camera.finishCornerSearch(on:[],off:[]);return }
            guard !Task.isCancelled else { _=await camera.finishCornerSearch(on:[],off:[]);return }
            let span=(start+0.6)...max(start+0.6,CACurrentMediaTime())
            if phase.isMultiple(of:2) { off.append(span) } else { on.append(span) }
        }
        let found=await camera.finishCornerSearch(on:on,off:off)
        guard !Task.isCancelled else { return }
        live.foundGoal(found)
    }

    private func recordTest() {
        recordingTask=Task { @MainActor in
            camera.startRecording(extra:["mode":challenge.mode?.rawValue ?? "physical-penalty-reactions","savesArmed":false,"keeper":live.telemetry.json,"challenge":challenge.snapshot])
            testMessage="Recording — roll or pass the real ball toward the wall."
            do { try await Task.sleep(for:.seconds(20)) } catch { }
            await camera.stopRecording(extra:["stopReason":"physical_camera_test","keeperEnd":live.telemetry.json,"challengeEnd":challenge.snapshot])
            testMessage=camera.recordingState == .saved ? "Test saved for review." : "Recording could not be saved."
            recordingTask=nil
        }
    }
}
#endif
