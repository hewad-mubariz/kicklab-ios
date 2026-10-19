#if DEBUG && BALL_DETECTION_DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Deterministic rendering of the real board on Simulator, whose camera cannot
/// run the wall experiment. This entry point is absent from the phone build.
struct WallTargetsPreviewScene: View {
    @StateObject private var model = WallTargetsModel(defaults: UserDefaults(suiteName: "WallGamePreview.\(UUID().uuidString)")!)

    private var previewBoard: some View {
        WallTargetsBoard(model: model, onStart: { _ = model.beginGameSetup() }, onSettings: {},
                         onStop: { model.finishSession(); model.recordingState = .saved },
                         runtime: ProcessInfo.processInfo.arguments.contains("--wall-runtime")
                            ? WallRuntimeSample(memoryMiB: 486, peakMemoryMiB: 512, thermalState: 2,
                                analysisFPS: 24, captureFPS: 60, inferenceMS: 32, cameraResting: false) : nil)
    }

    var body: some View {
        previewBoard
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear {
                defer { exportBoard() }
                WallTargetsAppDelegate.lock(.landscapeRight)
                model.style = .metal
                let state = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--wall-state=") }?
                    .replacingOccurrences(of: "--wall-state=", with: "") ?? "playing"
                if state == "searching" { model.beginCalibration(); model.cornerDots = .large; return }
                if state == "focusing" { model.beginCalibration(); model.isFocusing = true; return }
                if state == "focus-failed" { model.focusAcquisitionFailed(); return }
                if state == "failed" { model.calibrationFailed(); return }
                model.setCorners([CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                                  CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)])
                if state == "mapping" { model.beginMappingCheck(); model.mappingDotsVisible = true; return }
                // Synthetic UI state only. Physical builds get this report from camera observations.
                model.finishMappingCheck(.init(status: state == "mapping-failed" ? .missingPoints : .passed,
                    cornersNormalised: model.corners.map { [Double($0.x), Double($0.y)] },
                    frameWidth: 1280, frameHeight: 720, samples: [], limitCells: WallMappingCheck.limit))
                if state == "mapping-failed" { return }
                if state == "reference" {
                    model.beginReference(); model.showReference(box: 4, progress: 0.65); return
                }
                model.finishReference(Array(repeating: 0.04, count: 6))
                if ["intro", "cleared", "stopped", "saving"].contains(state) {
                    let previous = Date().addingTimeInterval(-100)
                    model.startPlay(at: previous)
                    for box in 1...6 {
                        model.record(box: box, u: Double((box - 1) % 3) + 0.5,
                                     v: Double((box - 1) / 3) + 0.5,
                                     at: previous.addingTimeInterval(Double(box) * 4.8))
                    }
                    model.newRound()
                }
                if state == "intro" { model.showGameIntro(); return }
                if state == "countdown" { model.countdown = 3; model.notice = "Board aligned · get ready"; return }
                let start = Date().addingTimeInterval(-18)
                model.startPlay(at: start)
                if state == "go" { model.showGoCue(); return }
                model.recordingState = .recording
                for box in ["cleared", "saving"].contains(state) ? Array(1...6) : [4, 5] {
                    model.record(box: box, u: Double((box - 1) % 3) + (box.isMultiple(of: 2) ? 0.7 : 0.3),
                                 v: Double((box - 1) / 3) + 0.35,
                                 at: start.addingTimeInterval(Double(box) * 3.1))
                }
                if state == "cleared" { model.recordingState = .saved }
                if state == "saving" { model.recordingState = .saving }
                if state == "stopped" { model.finishSession(); model.recordingState = .saved }
                if state == "paused" {
                    model.applyAlignment(.init(status: .obscured, corners: model.corners, revision: 2), at: Date().addingTimeInterval(-5))
                }
                if state == "contact" {
                    model.applyAlignment(.init(status: .obscured, corners: model.corners, revision: 2))
                    model.showContactPreview(.init(t: 10, x: 600, y: 250, d: 44, turn: 70,
                                                   u: 1.7, v: 0.65, box: 2))
                }
            }
    }

    private func exportBoard() {
        let renderer = ImageRenderer(content: previewBoard
            .frame(width: 1600, height: 900))
        renderer.scale = 1
        guard let data = renderer.uiImage?.pngData() else { return }
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("wall-board-preview.png"), options: .atomic)
        let projector = ImageRenderer(content: WallTargetsBoard(model: model).frame(width: 1600, height: 900))
        projector.scale = 1
        if let data = projector.uiImage?.pngData() {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("wall-projector-preview.png"), options: .atomic)
        }
    }
}
#endif
