#if DEBUG && BALL_DETECTION_DEBUG
import QuartzCore
import SwiftUI

/// The projected board stays visible through setup. Scoring starts only after
/// fresh, valid corners and a three-second countdown. A failed search stays paused.
struct WallTargetsPlayView: View {
    @ObservedObject var model: WallTargetsModel
    @ObservedObject var camera: WallTargetsCamera
    @Environment(\.dismiss) private var dismiss
    @State private var recordingSince: Date?
    @State private var attempt = 0
    let feedback: WallTargetsFeedback
    @State private var ending = false
    @State private var requestedStart = false
    @State private var saveFinished = true
    @State private var finishTask: Task<Void, Never>?
    @State private var openedPenaltyArgument=false
    @State private var reusedSetup = false
    @State private var savedFolder: URL?
    @State private var resultReady = false
    @State private var showSetupGuide = false

    private var allowsSetupReuse: Bool {
#if WALL_GAMES_PREVIEW
        true
#else
        false
#endif
    }

    var body: some View {
        Group {
#if WALL_GAMES_PREVIEW
            if model.gameScreen == .intro || (model.gameScreen == .results && resultReady) {
                WallArcadeRoundScreen(model:model,
                    startEnabled:camera.isReady && saveFinished && camera.runtime.canStartRound,
                    startStatus:camera.runtime.startNotice ?? (camera.isReady ? nil:camera.status),
                    saveFinished:saveFinished,savedFolder:savedFolder,onStart:startGame,
                    onClose:{ endSession(reason:"games",returnToSettings:true) },
                    onSetup:{ model.arcadeSetupGuidePresented=true;showSetupGuide=true })
            } else if model.projectorConnected {
                WallArcadePhoneController(model:model,camera:camera,ending:ending,
                    onRetry:retrySetup,onStop:{ endSession(reason:"stop_button") })
            } else {
                WallTargetsBoard(model:model,showsGameScreens:false,runtime:camera.runtime)
                    .overlay(alignment:.bottom) {
                        Button { endSession(reason:"stop_button") } label: {
                            Image(systemName:"stop.fill").font(.system(size:16,weight:.semibold))
                                .frame(width:32,height:32)
                        }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).tint(.white)
                            .foregroundStyle(.white).padding(.bottom,4)
                            .accessibilityLabel("Stop and save round").accessibilityIdentifier("arcade-stop-round")
                    }
            }
#else
        WallTargetsBoard(model: model, onStart: startGame,
                         onSettings: { endSession(reason: "settings", returnToSettings: true) },
                         onPenalties: { VirtualPenaltyPresentation.shared.open(realBall:true) },
                         onChallenge: { VirtualPenaltyPresentation.shared.open(realBall:true,challenge:$0) },
                         startEnabled: camera.isReady && saveFinished && camera.runtime.canStartRound,
                         startStatus: camera.runtime.startNotice ?? (camera.isReady ? nil : camera.status),
                         runtime: camera.runtime)
#endif
        }
#if WALL_GAMES_PREVIEW
            .fullScreenCover(isPresented:$showSetupGuide,onDismiss:{
                camera.setFramingPreview(false)
                model.arcadeSetupGuidePresented=false
                WallTargetsAppDelegate.lock(.landscapeRight)
            }) {
                WallArcadeSetupGuide(model:model,camera:camera,returnsToGame:true)
            }
            .onChange(of:model.projectorConnected) { _,_ in
                // The physical canvas changed. Finish the recording before a new
                // setup, rather than scoring with geometry from the other display.
                if requestedStart && !ending { endSession(reason:"display_changed") }
            }
            .task(id:model.gameScreen) {
                resultReady=false
                guard model.gameScreen == .results else { return }
                if model.clearedAt != nil {
                    let delay=model.game == .brickBlast ? WallBrickExplosion.duration:model.game.isParty ? 2.5:model.game.isArcade ? 0.7:0.35
                    do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                }
                resultReady=true
            }
#endif
            .contentShape(Rectangle())
            .onTapGesture {
#if WALL_GAMES_PREVIEW
                guard !model.projectorConnected else { return }
#endif
                guard requestedStart, !ending, model.gameScreen == .board else { return }
                if model.calibration == .failed || model.referenceFailed || model.mappingFailed {
                    model.invalidateCalibration()
                    attempt += 1
                }
            }
            .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 40) {
                endSession(reason: "long_press", returnToSettings: model.gameScreen != .board)
            }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
#if !WALL_GAMES_PREVIEW
            .modifier(VirtualPenaltyCover(camera:camera))
#endif
            .onAppear {
                guard !model.arcadeSetupGuidePresented else { return }
                WallTargetsAppDelegate.lock(.landscapeRight)
                model.showGameIntro()
                camera.setScoringEnabled(false)
                camera.setCaptureResting(true)
            }
            .task {
                let args=ProcessInfo.processInfo.arguments
                let challenge=GoalChallengeMode.launchMode(args)
#if WALL_GAMES_PREVIEW
                guard challenge == .topBins else { return }
#endif
                guard !openedPenaltyArgument,args.contains("--virtual-penalties") || challenge != nil else { return }
                // The diagnostic launch shortcut must wait for the containing
                // wall-game cover to finish presenting before opening its cover.
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                openedPenaltyArgument=true
                VirtualPenaltyPresentation.shared.open(realBall:!args.contains("--penalty-demo"),challenge:challenge)
            }
            .onChange(of: camera.runtime.shouldEndRound) { _, critical in
                if critical { endSession(reason: "thermal_critical") }
            }
            .onChange(of: model.sessionEnded) { _, ended in
                if ended && !ending {
                    endSession(reason: model.arcadeWon == false ? "round_lost" : "round_complete")
                }
            }
            .onChange(of: model.needsGameplayInference, initial: true) { _, enabled in
                camera.setGameplayInputEnabled(enabled)
            }
            .onChange(of: camera.recordingState, initial: true) { _, state in
                model.recordingState = state
            }
            .sensoryFeedback(.success, trigger: model.lastHit?.id)
            .onChange(of: camera.status) { _, status in
                if !camera.isReady, requestedStart, !ending { model.notice = status }
            }
            .onDisappear {
                guard !model.arcadeSetupGuidePresented else { return }
                endSession(reason: "view_closed")
            }
            .task(id: "\(camera.isReady)-\(attempt)-\(ending)-\(requestedStart)") {
                guard requestedStart, !ending else { return }
                guard camera.isReady else {
                    camera.endReference()
                    model.invalidateCalibration()
                    model.notice = camera.status
                    camera.setScoringEnabled(false)
                    endSession(reason: "camera_interrupted")
                    return
                }
                await prepareGame()
            }
            .task(id: "\(model.game.rawValue)-\(model.isPlaying)") {
                guard model.game.isArcade else { return }
                while model.isPlaying && !Task.isCancelled {
                    if let cue = model.tickArcade().last { feedback.play(cue) }
                    camera.setGameplayInputEnabled(model.needsGameplayInference)
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
    }

    private func retrySetup() {
        guard requestedStart, !ending, model.gameScreen == .board else { return }
        model.invalidateCalibration()
        attempt += 1
    }

    private func startGame() {
        guard camera.isReady, saveFinished, camera.runtime.canStartRound, !requestedStart || ending,
              model.beginGameSetup(usingCurrentCorners: !requestedStart, reusingSetup: allowsSetupReuse) else { return }
        camera.setCaptureResting(false)
        finishTask = nil
        savedFolder = nil
        ending = false
        requestedStart = true
        attempt += 1
    }

    private func prepareGame() async {
        camera.setScoringEnabled(false)
        camera.setTargetLayout(model.game.layout)
        model.pause()
        camera.endReference()
        reusedSetup = false
        if allowsSetupReuse, model.hasReusableSetup,
           let setup = model.reusableSetup, let reference = model.wallReference,
           await camera.restoreSetup(setup, reference: reference) {
            model.notice = "Checking your wall · keep the four corners clear"
            startSetupRecording()
            await camera.verifyAlignment()
            if await waitForAlignment(timeout: 8),
               let observed = camera.alignmentUpdate?.corners,
               setup.accepts(corners: observed, frameSize: camera.frameSize) {
                reusedSetup = true
                camera.endReference(beginCountdown: true)
            } else if !Task.isCancelled {
                model.invalidateCalibration()
            }
        } else if allowsSetupReuse && model.hasReusableSetup {
            model.invalidateCalibration()
        }
        guard !Task.isCancelled else { return }
        if !reusedSetup {
        // A manually confirmed board can be used for this open session. Saved
        // corners from a previous camera session are never trusted automatically.
        if model.calibration != .ready {
            model.beginCalibration()
            guard await pause(.milliseconds(1000)) else { return }
            guard await focusOnWall() else { return }
            startSetupRecording()
            await camera.beginCornerSearch()
            var on: [ClosedRange<Double>] = [], off: [ClosedRange<Double>] = []
            for phase in 0..<4 {
                model.cornerDots = phase.isMultiple(of: 2) ? .hidden : .large
                let start = CACurrentMediaTime()
                guard await pause(.milliseconds(1200)) else {
                    model.cornerDots = .normal
                    _ = await camera.finishCornerSearch(on: [], off: [])
                    return
                }
                // Ignore display transport latency and use the stable half of each blink.
                let span = (start + 0.6)...max(start + 0.6, CACurrentMediaTime())
                if phase.isMultiple(of: 2) { off.append(span) } else { on.append(span) }
            }
            let corners = await camera.finishCornerSearch(on: on, off: off)
            guard !Task.isCancelled else { return }
            model.cornerDots = .normal
            guard let corners, model.setCorners(corners) else {
                model.calibrationFailed()
                return
            }
        }
        camera.setCorners(model.corners)
        // Once the board is located, acquire at its centre before measuring ball
        // diameters. A later refocus would change apparent size and invalidate them.
        guard await focusOnWall(near: model.corners) else { return }
        model.newRound()
        startSetupRecording()
        // The normal-marker view may arrive after the blinking calibration.
        // Verify the actual visible board before collecting any wall-size samples.
        await camera.verifyAlignment()
        guard await waitForAlignment(timeout: 8) else { return }
        guard await checkMapping() else { return }
        // Restore the normal board and re-observe its corner dots after the check.
        await camera.verifyAlignment()
        guard await waitForAlignment(timeout: 8) else { return }
        if let report = model.mappingReport,
           zip(report.cornersNormalised, model.corners).contains(where: { old, new in
               hypot((old[0] - new.x) * report.frameWidth,
                     (old[1] - new.y) * report.frameHeight) > WallBoardAlignment.tolerancePixels
           }) {
            model.invalidateCalibration()
            model.calibrationFailed()
            model.notice = "Board moved during the check · tap to retry"
            return
        }
        model.beginReference()
        var diameters: [Double] = []
        for box in [WallReferenceCollector.wallCentre] {
            model.showReference(box: box, progress: 0)
            await camera.beginReference(box: box)
            while !Task.isCancelled, camera.isReady {
                if let sample = camera.referenceUpdate, sample.box == box {
                    model.showReference(box: box, progress: sample.progress)
                    if let diameter = sample.diameter {
                        diameters.append(diameter)
                        break
                    }
                }
                guard await pause(.milliseconds(100)) else { return }
            }
            guard !Task.isCancelled, camera.isReady else { return }
        }
        camera.endReference()
        guard model.finishReference(diameters), let reference = model.wallReference else { return }
        camera.setReference(reference)
        camera.endReference(beginCountdown: true)
        model.notice = "Reference saved · step back and to the side"
        guard await pause(.seconds(3)) else { return }
        model.rememberSetup(frameSize: camera.frameSize)
        }
        await camera.verifyAlignment()
        // Losing alignment during countdown restarts it; the first shot must
        // never be taken against geometry that became stale during setup.
        feedback.prepare()
        while !Task.isCancelled, camera.isReady {
            model.countdown = nil
            guard await waitForAlignment() else { return }
            model.notice = "Get ready · release the ball when you shoot"
            var uninterrupted = true
            for number in (1...3).reversed() {
                model.countdown = number
                guard await pause(.seconds(1)) else { return }
                if camera.alignmentUpdate?.status != .ready { uninterrupted = false; break }
            }
            if uninterrupted, model.startPlay() { break }
        }
        guard !Task.isCancelled, camera.isReady, model.isPlaying else { return }
        camera.setGameplayInputEnabled(model.needsGameplayInference)
        camera.setScoringEnabled(true)
        camera.markPlaying()
        model.showGoCue()

    }

    private func checkMapping() async -> Bool {
        model.beginMappingCheck()
        await camera.beginMappingCheck()
        var on: [ClosedRange<Double>] = [], off: [ClosedRange<Double>] = []
        for phase in 0..<4 {
            model.mappingDotsVisible = !phase.isMultiple(of: 2)
            let start = CACurrentMediaTime()
            guard await pause(.milliseconds(1200)) else {
                model.mappingDotsVisible = false
                _ = await camera.finishMappingCheck(on: [], off: [])
                return false
            }
            let span = (start + 0.6)...max(start + 0.6, CACurrentMediaTime())
            if phase.isMultiple(of: 2) { off.append(span) } else { on.append(span) }
        }
        let report = await camera.finishMappingCheck(on: on, off: off)
        guard !Task.isCancelled else { return false }
        return model.finishMappingCheck(report)
    }

    private func focusOnWall(near corners: [CGPoint]? = nil) async -> Bool {
        model.isFocusing = true
        let focused = await camera.acquireFocus(near: corners)
        model.isFocusing = false
        guard !Task.isCancelled else { return false }
        if !focused { model.focusAcquisitionFailed() }
        return focused
    }

    private func startSetupRecording() {
        guard recordingSince == nil else { return }
        recordingSince = Date()
        camera.startRecording(extra: ["style": model.style.rawValue, "mode": "setup-and-play",
            "game": model.game.rawValue, "timeBasis": "active-play-excluding-alignment-pauses",
            "boardPadding": Double(WallTargetsBoard.padding),
            "app": "Ball Detection Debug / Wall targets"].merging(model.gameMetadata) { _, game in game })
    }

    private func waitForAlignment(timeout: TimeInterval? = nil) async -> Bool {
        let started = CACurrentMediaTime()
        while !Task.isCancelled, camera.isReady {
            if camera.alignmentUpdate?.status == .referenceRequired { return false }
            if camera.alignmentUpdate?.status == .ready { return true }
            if let timeout, CACurrentMediaTime() - started >= timeout {
                model.alignmentSetupFailed()
                camera.setScoringEnabled(false)
                return false
            }
            guard await pause(.milliseconds(100)) else { return false }
        }
        return false
    }

    private func endSession(reason: String, returnToSettings: Bool = false) {
        guard requestedStart else {
            if returnToSettings {
#if WALL_GAMES_PREVIEW
                model.showGameIntro(); dismiss()
#else
                camera.setCaptureResting(false)
                model.showBoardForSettings(); dismiss()
#endif
            }
            return
        }
        if !ending {
            ending = true
            saveFinished = false
            let captured = recordingSince != nil
            let since = recordingSince ?? .distantPast
            recordingSince = nil
            model.cornerDots = .normal
            model.finishSession()
            camera.endReference()
            camera.setScoringEnabled(false)
            let summary: [String: Any] = [
                "stopReason": reason,
                "setupReused": reusedSetup,
                "game": model.game.rawValue,
                "activePlaySeconds": model.elapsed(at: Date()),
                "uniqueTargets": model.boxesHit.count,
                "personalBestSeconds": model.bestClearTime as Any? ?? NSNull(),
                "newPersonalBest": model.isNewBest,
                "clears": model.clears.filter { $0.at >= since }.map(\.seconds),
                "scoredHits": model.hits.enumerated().map { index, hit in
                    ["number": index + 1, "box": hit.box as Any? ?? NSNull(),
                     "u": hit.u, "v": hit.v, "reportedAt": hit.at.timeIntervalSince1970,
                     "approachSpeed": hit.approachSpeed as Any? ?? NSNull(),
                     "footprint": hit.footprint?.json as Any? ?? NSNull(),
                     "brickDamage": hit.brickDamage.map(\.json),
                     "remainingHealth": (model.game == .brickBlast ? hit.brickDamage.first(where: { $0.id == hit.box })?.after : 0) as Any? ?? NSNull()] as [String: Any]
                },
                "calibrationValid": model.calibration == .ready,
                "wallBallDiametersNormalised": model.wallReference?.diameters ?? [],
                "cornersNormalised": model.corners.map { [Double($0.x), Double($0.y)] },
                "processingFPS": camera.processingFPS, "deliveredFPS": camera.deliveredFPS]
                .merging(model.gameMetadata) { _, game in game }
            camera.updateRecordingMetadata(summary)
            finishTask = Task {
#if WALL_GAMES_PREVIEW
                // Retain the last projected hit/reaction in the camera replay.
                // Scoring has already stopped and the active timer is frozen.
                if reason == "round_complete" || reason == "round_lost" {
                    try? await Task.sleep(for:.seconds(2.0))
                }
#endif
                await camera.stopRecording(extra: summary)
                camera.setCaptureResting(true)
                if captured, camera.recordingState == .saved { savedFolder = camera.lastRecording }
                saveFinished = true
            }
        }
        if returnToSettings {
            let pending = finishTask
            Task {
                await pending?.value
#if WALL_GAMES_PREVIEW
                model.showGameIntro()
#else
                camera.setCaptureResting(false)
                model.showBoardForSettings()
#endif
                dismiss()
            }
        }
    }

    private func pause(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration); return true }
        catch { return false }
    }
}
#endif
