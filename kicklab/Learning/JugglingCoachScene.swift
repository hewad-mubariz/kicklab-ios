import SwiftUI
import SceneKit
import simd

struct JugglingCoachStage: View {
    let motion: CoachMotion
    var playing = true
    var slow = false
    var sideView = false
    var speaking = false
    var showsPhase = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var started = Date()
    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var rate = 1.0

    private var shouldRun: Bool { visible && playing && scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !running)) { context in
            let seconds = elapsed + (running ? context.date.timeIntervalSince(started) * rate : 0)
            let pose = CoachPose.sample(motion, progress: seconds / motion.duration)
            ZStack(alignment: .bottom) {
                CoachSceneSurface(pose: pose, time: seconds, sideView: sideView, speaking: speaking && running)
                    .padding(.bottom, showsPhase ? 26 : 0)
                    .accessibilityHidden(true)
                if showsPhase {
                    Text(pose.phase.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.bottom, 14)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animated juggling demonstration")
        .accessibilityValue(reduceMotion ? "Animation paused for Reduce Motion. Written steps are below." : (playing ? "Playing" : "Paused"))
        .onAppear { visible = true; synchronize() }
        .onDisappear { visible = false; synchronize() }
        .onChange(of: shouldRun) { _, _ in synchronize() }
        .onChange(of: slow) { _, _ in synchronize() }
        .onChange(of: motion) { _, _ in elapsed = 0; started = Date() }
    }

    private func synchronize() {
        let now = Date()
        if running { elapsed += now.timeIntervalSince(started) * rate }
        started = now
        rate = slow ? 0.5 : 1
        running = shouldRun
    }
}

private struct CoachSceneSurface: UIViewRepresentable {
    let pose: CoachPose
    let time: Double
    let sideView: Bool
    let speaking: Bool

    func makeCoordinator() -> CoachScene { CoachScene() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(pose, time: time, sideView: sideView, speaking: speaking)
    }
    static func dismantleUIView(_ view: SCNView, coordinator: CoachScene) {
        view.isPlaying = false
        view.scene = nil
    }
}
