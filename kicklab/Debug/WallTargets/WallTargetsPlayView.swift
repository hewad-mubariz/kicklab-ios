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
    @State private var feedback = WallTargetsFeedback()

    var body: some View {
        WallTargetsBoard(model: model)
            .contentShape(Rectangle())
            .onTapGesture {
                if model.calibration == .failed || model.referenceFailed
                    || (model.referenceBox == nil && model.calibration == .ready && model.alignmentStatus != .ready) {
                    model.invalidateCalibration()
                    attempt += 1
                }
            }
            .onLongPressGesture(minimumDuration: 0.8) { dismiss() }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onChange(of: model.lastHit?.id) { _, id in
                if id != nil, model.isPlaying { feedback.play(cleared: model.clearedAt != nil) }
            }
            .sensoryFeedback(.success, trigger: model.lastHit?.id)
            .onChange(of: camera.status) { _, status in
                if !camera.isReady { model.notice = status }
            }
            .onDisappear {
                model.cornerDots = .normal
                model.pause()
                camera.endReference()
                camera.setScoringEnabled(false)
                finishRecording()
            }
            .task(id: "\(camera.isReady)-\(attempt)") {
                guard camera.isReady else {
                    camera.endReference()
                    finishRecording()
                    model.invalidateCalibration()
                    model.notice = camera.status
                    camera.setScoringEnabled(false)
                    return
                }
                await prepareGame()
            }
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
                                         "boardPadding": Double(WallTargetsBoard.padding),
                                         "app": "Ball Detection Debug / Wall targets"])
        }
        // The normal-marker view may arrive after the blinking calibration.
        // Verify the actual visible board before collecting any wall-size samples.
        await camera.verifyAlignment()
        guard await waitForAlignment() else { return }
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
                        feedback.play(cleared: false)
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

    private func finishRecording() {
        guard let since = recordingSince else { return }
        recordingSince = nil
        camera.stopRecording(extra: [
            "clears": model.clears.filter { $0.at >= since }.map(\.seconds),
            "calibrationValid": model.calibration == .ready,
            "wallBallDiametersNormalised": model.wallReference?.diameters ?? [],
            "cornersNormalised": model.corners.map { [Double($0.x), Double($0.y)] },
            "processingFPS": camera.processingFPS, "deliveredFPS": camera.deliveredFPS])
    }

    private func pause(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration); return true }
        catch { return false }
    }
}
#endif
