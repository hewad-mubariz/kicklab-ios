#if DEBUG && TOUCH_COUNTING_DEBUG
import SwiftUI

struct DebugFrameTestControls: View {
    @ObservedObject var camera: CameraSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Menu {
                Picker("Analysis frame rate", selection: Binding(
                    get: { camera.debugFrameProfile },
                    set: { camera.setDebugFrameProfile($0) })) {
                    ForEach(DebugFrameProfile.allCases, id: \.self) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
            } label: {
                HStack {
                    Label("Frame test", systemImage: "speedometer")
                    Spacer()
                    Text(camera.debugFrameProfile.title)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .disabled(camera.isRecording || camera.isPreparingRecording || camera.isFinishingRecording)
            .accessibilityIdentifier("debug-frame-profile")

            if camera.isRecording {
                let stats = camera.debugFrameTest
                Text("Camera \(stats.receivedFPS, specifier: "%.0f") fps · Analysis \(camera.fps, specifier: "%.1f") fps")
                Text("Skipped \(stats.skipped) · Camera drops \(stats.captureDrops) · Writer drops \(stats.writerDrops)")
                Text("Busy replaced \(stats.replaced) · Largest analysis gap \(stats.maxAnalysisGapMS, specifier: "%.0f") ms")
            } else {
                Text(camera.debugFrameProfile.hasGaps
                     ? "Skips 200 ms every 3 s. Original video stays full rate."
                     : "Changes analysis only. Original video stays full rate.")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }
}
#endif
