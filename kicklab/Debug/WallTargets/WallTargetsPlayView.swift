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

    var body: some View {
        WallTargetsBoard(model: model, onStart: startGame,
                         onSettings: { endSession(reason: "settings", returnToSettings: true) },
                         onStop: requestedStart && !ending ? { endSession(reason: "stop_button") } : nil,
                         startEnabled: camera.isReady && saveFinished && camera.runtime.canStartRound,
                         startStatus: camera.runtime.startNotice ?? (camera.isReady ? nil : camera.status),
                         runtime: camera.runtime)
            .contentShape(Rectangle())
            .onTapGesture {
                guard requestedStart, !ending, model.gameScreen == .board else { return }
                if model.calibration == .failed || model.referenceFailed || model.mappingFailed
                    || (model.referenceBox == nil && model.calibration == .ready && model.alignmentStatus != .ready) {
                    model.invalidateCalibration()
                    attempt += 1
                }
            }
            .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 40) {
                endSession(reason: "long_press", returnToSettings: model.gameScreen != .board)
            }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear {
                model.showGameIntro()
                camera.setScoringEnabled(false)
                camera.setCaptureResting(true)
            }
            .onChange(of: camera.runtime.shouldEndRound) { _, critical in
                if critical { endSession(reason: "thermal_critical") }
            }
            .onChange(of: model.clearedAt) { _, date in
                if date != nil { endSession(reason: "round_complete") }
            }
            .onChange(of: camera.recordingState, initial: true) { _, state in
                model.recordingState = state
            }
            .sensoryFeedback(.success, trigger: model.lastHit?.id)
            .onChange(of: camera.status) { _, status in
                if !camera.isReady, requestedStart, !ending { model.notice = status }
            }
            .onDisappear {
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
    }

    private func startGame() {
        guard camera.isReady, saveFinished, camera.runtime.canStartRound, !requestedStart || ending,
              model.beginGameSetup(usingCurrentCorners: !requestedStart) else { return }
        camera.setCaptureResting(false)
        finishTask = nil
        ending = false
        requestedStart = true
        attempt += 1
    }

    private func prepareGame() async {
        camera.setScoringEnabled(false)
        model.pause()
        camera.endReference()
        // A manually confirmed board can be used for this open session. Saved
        // corners from a previous camera session are never trusted automatically.
        if model.calibration != .ready {
            model.beginCalibration()
            guard await pause(.milliseconds(1000)) else { return }
            guard await focusOnWall() else { return }
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
        // Save the reference pass too; gameplay is explicitly disabled throughout.
        if recordingSince == nil {
            recordingSince = Date()
            camera.startRecording(extra: ["style": model.style.rawValue, "mode": "reference-and-play",
                                         "game": "clear-the-wall-v1", "timeBasis": "active-play-excluding-alignment-pauses",
                                         "boardPadding": Double(WallTargetsBoard.padding),
                                         "app": "Ball Detection Debug / Wall targets"])
        }
        // The normal-marker view may arrive after the blinking calibration.
        // Verify the actual visible board before collecting any wall-size samples.
        await camera.verifyAlignment()
        guard await waitForAlignment() else { return }
        guard await checkMapping() else { return }
        // Restore the normal board and re-observe its corner dots after the check.
        await camera.verifyAlignment()
        guard await waitForAlignment() else { return }
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
        for box in 1...6 {
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
        model.notice = "Reference saved · step back and to the side"
        guard await pause(.seconds(3)) else { return }
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

    private func waitForAlignment() async -> Bool {
        while !Task.isCancelled, camera.isReady {
            if camera.alignmentUpdate?.status == .referenceRequired { return false }
            if camera.alignmentUpdate?.status == .ready { return true }
            guard await pause(.milliseconds(100)) else { return false }
        }
        return false
    }

    private func endSession(reason: String, returnToSettings: Bool = false) {
        guard requestedStart else {
            if returnToSettings {
                camera.setCaptureResting(false)
                model.showBoardForSettings(); dismiss()
            }
            return
        }
        if !ending {
            ending = true
            saveFinished = false
            let since = recordingSince ?? .distantPast
            recordingSince = nil
            model.cornerDots = .normal
            model.finishSession()
            camera.endReference()
            camera.setScoringEnabled(false)
            let summary: [String: Any] = [
                "stopReason": reason,
                "game": "clear-the-wall-v1",
                "activePlaySeconds": model.elapsed(at: Date()),
                "uniqueTargets": model.boxesHit.count,
                "personalBestSeconds": model.bestClearTime as Any? ?? NSNull(),
                "newPersonalBest": model.isNewBest,
                "clears": model.clears.filter { $0.at >= since }.map(\.seconds),
                "scoredHits": model.hits.enumerated().map { index, hit in
                    ["number": index + 1, "box": hit.box as Any? ?? NSNull(),
                     "u": hit.u, "v": hit.v, "reportedAt": hit.at.timeIntervalSince1970] as [String: Any]
                },
                "calibrationValid": model.calibration == .ready,
                "wallBallDiametersNormalised": model.wallReference?.diameters ?? [],
                "cornersNormalised": model.corners.map { [Double($0.x), Double($0.y)] },
                "processingFPS": camera.processingFPS, "deliveredFPS": camera.deliveredFPS]
            finishTask = Task {
                await camera.stopRecording(extra: summary)
                camera.setCaptureResting(true)
                saveFinished = true
            }
        }
        if returnToSettings {
            let pending = finishTask
            Task {
                await pending?.value
                camera.setCaptureResting(false)
                model.showBoardForSettings()
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
