#if DEBUG
import SwiftUI

struct FinalTestPanel: View {
    var settingsLocked = false
    @ObservedObject private var tests = FinalTestCoordinator.shared
    @AppStorage(ShoeRecoveryPolicy.benchmarkPreferenceKey) private var toeRecoveryEnabled = true
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var expected = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Duration ladder") {
                    Toggle("Toe recovery (MediaPipe)", isOn: Binding(
                        get: { ShoeRecoveryPolicy.launchOverride ?? toeRecoveryEnabled },
                        set: { toeRecoveryEnabled = $0 }))
                        .disabled(settingsLocked || tests.busy || tests.analysisRunning
                                  || !ShoeRecoveryPolicy.available || ShoeRecoveryPolicy.launchOverride != nil)
                        .accessibilityIdentifier("final-test-toe-recovery")
                    Text("On adds the heel/toe pose model. Off skips it. The ball detector, Apple Vision and existing contact rules stay the same. Applies to the next recording or fresh analysis.")
                        .font(.caption).foregroundStyle(.secondary)
                    if settingsLocked || tests.busy || tests.analysisRunning {
                        Text("Finish the current run before changing this setting.").font(.caption)
                    } else if ShoeRecoveryPolicy.launchOverride != nil {
                        Text("The launch command fixes this mode. Reopen from the app icon to use the switch.").font(.caption)
                    }
                    Text("Choose a duration, then record in the camera. It stops at the target. Keep the player and ball visible; include both feet, knees, head and chest, plus deliberate hand catches and ground bounces.")
                        .font(.footnote)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 85))]) {
                        ForEach(FinalTestReport.durations, id: \.self) { seconds in
                            Button(FinalTestCoordinator.label(seconds)) { tests.arm(seconds); dismiss() }
                                .buttonStyle(.bordered).disabled(settingsLocked || tests.busy || tests.analysisRunning)
                                .accessibilityIdentifier("final-test-arm-\(seconds)")
                        }
                    }
                    Text(tests.message).font(.footnote)
                    if tests.armedSeconds != nil { Button("Disarm", role: .cancel) { tests.disarm() } }
                }
                Section("Outdoor measurements") {
                    Text("The camera overlay shows the active toe mode, touches, heat, app memory, battery, FPS, frame drops and MediaPipe Full pose cost on CPU. Off runs should show zero MediaPipe calls.")
                    Text("Reports keep one-second samples and exact final pose totals. Pose work is already included in full-frame time. Memory around pose initialization is a whole-app change, not model-only RAM.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Start with 30 seconds to check framing, then try 3, 10 and 30 minutes. Keep lighting and movement similar when comparing phones; let each phone return to Normal thermal state between comparisons.")
                        .font(.caption)
                }
                if let report = tests.report {
                    Section("\(FinalTestCoordinator.label(report.targetSeconds)) · \(report.toeRecoveryLabel) · \(report.verdict)") {
                        Text("\(report.build) · \(report.started.formatted())").font(.caption)
                        Text("Peak \(report.peakMemoryMiB, specifier: "%.0f") MiB · worst thermal: \(report.worstThermal)")
                        Text("Live: \(report.liveTouches.map(String.init) ?? "—") · fresh analysis: \(report.analyzedTouches.map(String.init) ?? "—")")
                        if let enabled = report.analysisShoeRecoveryEnabled {
                            Text("Fresh analysis · Toe: \(enabled ? "On" : "Off")").font(.caption)
                        }
                        if let pose = report.livePerformance?.shoePose {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Pose Full · CPU\(pose.enabled ? "" : " · disabled")").font(.headline)
                                Text("\(pose.calls) calls · \(pose.framesWithPose) frames with a pose · \(pose.errors) errors")
                                Text("Inference avg \(pose.meanInferenceMS, specifier: "%.1f") ms · max \(pose.maxInferenceMS, specifier: "%.1f") ms")
                                Text("Model load \(pose.loadMS, specifier: "%.0f") ms · total pose work \(pose.totalMS / 1000, specifier: "%.2f") seconds")
                                Text("\(pose.proofs) supported contact checks / \(pose.proofRequests) checks (not extra counted touches)")
                                if let delta = pose.observedLoadMemoryDeltaMiB {
                                    Text("Observed app change at pose load: \(delta, specifier: "%+.1f") MiB")
                                }
                            }.font(.caption)
                        }
                        if let capture = report.capture {
                            Text("\(capture.width)×\(capture.height) · \(capture.selectedFPS) fps · \(capture.writtenFrames) saved / \(capture.analysedFrames) analyzed frames").font(.caption)
                            Text("Drops: camera \(capture.captureDrops), writer \(capture.writerDrops); analysis replaced \(capture.analysisReplaced)").font(.caption)
                        }
                        ForEach(FinalTestReport.stageNames, id: \.self) { name in
                            if let stage = report.stages[name] {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text(name.capitalized); Spacer(); Text(stage.status).foregroundStyle(.secondary) }
                                    if !stage.detail.isEmpty { Text(stage.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if let error = report.storageError { Text(error).foregroundStyle(.red) }
                        if tests.analysisRunning {
                            ProgressView(value: tests.analysisProgress)
                            Button("Cancel analysis", role: .destructive) { tests.cancelAnalysis() }
                        } else {
                            Button("Analyze retained video from scratch") { tests.analyzeSavedVideo() }
                                .disabled(!tests.canAnalyze)
                                .accessibilityIdentifier("final-test-analyze")
                        }
                        Text("Fresh analysis decodes the entire saved video and keeps a separate count. Differences from live counting need visual review. Use the normal Download button to test export.")
                            .font(.caption)
                    }
                    Section("Manual review") {
                        ForEach(FinalTestReport.reviewNames, id: \.self) { key in
                            Picker(key, selection: Binding(get: { tests.report?.reviews[key] ?? "pending" },
                                set: { tests.review(key, value: $0) })) {
                                Text("Pending").tag("pending")
                                Text("Passed").tag("passed")
                                Text("Issues").tag("issues")
                            }
                        }
                        TextField("Hand-counted legitimate touches (optional)", text: $expected).keyboardType(.numberPad)
                        TextField("Missed / false touch timestamps, playback or heat issues", text: $notes, axis: .vertical).lineLimit(3...8)
                        Button("Save review notes") { tests.saveNotes(notes, expected: expected) }
                        Text("Check exported video in Photos too. Completed processing alone does not prove touch accuracy or a correct rendered counter/timer.").font(.caption)
                    }
                    Section("Evidence kept on this phone") {
                        if let folder = tests.folder {
                            Text("Files → On My iPhone → Juggle Dude → FinalValidation → \(folder.lastPathComponent)").font(.caption).textSelection(.enabled)
                            ShareLink("Share report JSON", item: folder.appendingPathComponent("report.json"))
                        }
                        if let video = tests.retainedVideo { ShareLink("Share original test video", item: video) }
                        Text("Each run keeps the original, exported video, one-second thermal/memory/frame samples, stage events and contact timestamps. No automatic upload or deletion.").font(.caption)
                    }
                }
                Section("Previous attempts") {
                    Button("Refresh reports") { tests.reloadHistory() }
                    ForEach(tests.history) { report in
                        Button {
                            tests.select(report); notes = report.notes; expected = report.expectedTouches.map(String.init) ?? ""
                        } label: {
                            VStack(alignment: .leading) {
                                Text("\(FinalTestCoordinator.label(report.targetSeconds)) · \(report.toeRecoveryLabel) · \(report.verdict)")
                                Text(report.started.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(tests.busy || tests.analysisRunning)
                    }
                }
            }
            .navigationTitle("Final validation")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                tests.reloadHistory()
                notes = tests.report?.notes ?? ""; expected = tests.report?.expectedTouches.map(String.init) ?? ""
            }
        }
    }
}
#endif
