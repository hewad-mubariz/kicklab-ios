#if DEBUG && BALL_DETECTION_DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Deterministic rendering of the real board on Simulator, whose camera cannot
/// run the wall experiment. This entry point is absent from the phone build.
struct WallTargetsPreviewScene: View {
    @StateObject private var model = WallTargetsModel()

    var body: some View {
        WallTargetsBoard(model: model)
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
                if state == "reference" {
                    model.beginReference(); model.showReference(box: 4, progress: 0.65); return
                }
                model.finishReference(Array(repeating: 0.04, count: 6))
                if state == "countdown" { model.countdown = 3; model.notice = "Board aligned · get ready"; return }
                let start = Date().addingTimeInterval(-18)
                model.startPlay(at: start)
                for box in state == "cleared" ? Array(1...6) : [4, 5] {
                    model.record(box: box, u: Double((box - 1) % 3) + 0.5, v: Double((box - 1) / 3) + 0.5,
                                 at: start.addingTimeInterval(Double(box)))
                }
                if state == "paused" {
                    model.applyAlignment(.init(status: .obscured, corners: model.corners, revision: 2), at: Date().addingTimeInterval(-5))
                }
            }
    }

    private func exportBoard() {
        let renderer = ImageRenderer(content: WallTargetsBoard(model: model)
            .frame(width: 1600, height: 900))
        renderer.scale = 1
        guard let data = renderer.uiImage?.pngData() else { return }
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("wall-board-preview.png"), options: .atomic)
    }
}
#endif
