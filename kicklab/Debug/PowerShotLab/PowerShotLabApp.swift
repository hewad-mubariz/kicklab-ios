#if POWER_SHOT_DEBUG
import SwiftUI

@main
struct PowerShotLabApp: App {
    var body: some Scene {
        WindowGroup { PowerShotLabView().preferredColorScheme(.dark) }
    }
}

struct PowerShotLabView: View {
    @StateObject private var capture = ShotGeometryCapture()
    @StateObject private var checklist = PowerShotChecklistStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLibrary = false
    @State private var showSetup = false
    @State private var showChecklist = false
    @State private var savedForReview: URL?
    @State private var pendingStart = false
    @State private var reference = PowerShotFieldReference()
    private var active: Bool { scenePhase == .active && !showLibrary }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Power Shot Lab").font(.title2.bold())
                        Text("EXPERIMENTAL · FIELD EVIDENCE").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Saved tests", systemImage: "tray.full") { showLibrary = true }
                        .labelStyle(.iconOnly).font(.title2)
                        .disabled(capture.recording || capture.finishing)
                        .accessibilityIdentifier("lab-saved-tests")
                }
                Button {
                    savedForReview = nil; showChecklist = true
                } label: {
                    HStack {
                        Image(systemName: "checklist")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Training checklist · \(checklist.completedCount)/\(checklist.requiredCount) done").font(.subheadline.bold())
                            Text("Now: \(checklist.selected.title)").font(.caption).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(8).background(.thinMaterial, in: .rect(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(capture.recording || capture.finishing)
                    .accessibilityIdentifier("lab-checklist")
                if geometry.size.width > geometry.size.height {
                    HStack {
                        preview
                        ScrollView { controls }.frame(width: min(380, geometry.size.width * 0.45))
                    }
                } else {
                    preview.frame(minHeight: 160, maxHeight: geometry.size.height * 0.34)
                    ScrollView { controls }
                }
                actions
                Text(capture.status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("lab-save-status")
            }.padding(12)
        }
        .sheet(isPresented: $showLibrary, onDismiss: { Task { await checklist.reload() } }) { ShotRecordingsView() }
        .sheet(isPresented: $showChecklist, onDismiss: { Task { await checklist.reload() } }) {
            PowerShotChecklistView(store: checklist, savedDirectory: savedForReview) { step in
                if !step.isSetup {
                    reference.kind = step.kind
                    if step.reference == "penalty" && reference.penalty == nil { reference.penalty = PowerShotPenaltyReference() }
                }
                showChecklist = false
            }
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                Form { PowerShotReferenceFields(reference: $reference, beforeRecording: true) }
                    .navigationTitle("Trial setup")
                    .toolbar { Button("Done") { checklist.saveSetupReference(reference); showSetup = false } }
            }
        }
        .sheet(item: Binding(get: { capture.calibrationSnapshot },
                             set: { _ in capture.cancelRollCalibration() })) { snapshot in
            ShotRollCalibrationView(snapshot: snapshot, apply: capture.applyRollCalibration,
                                    cancel: capture.cancelRollCalibration)
        }
        .task(id: active) {
            if active { await capture.prepare() } else { capture.pause() }
        }
        .onChange(of: active, initial: true) { _, running in UIApplication.shared.isIdleTimerDisabled = running }
        .onDisappear { capture.pause(); UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: capture.rollDisplay.canSetStart) { _, _ in armIfReady() }
        .onChange(of: capture.recording) { _, recording in if !recording { pendingStart = false } }
        .onChange(of: capture.labLastSavedDirectory) { _, directory in
            savedForReview = directory
            Task {
                checklist.confirmBackup(false)
                await checklist.reload()
                if scenePhase == .active { showChecklist = true }
            }
        }
        .task {
            reference = checklist.session.setupReference ?? PowerShotFieldReference()
            await checklist.reload()
        }
    }

    private var preview: some View {
        ShotGeometryPreview(capture: capture).clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .topLeading) {
                Text(capture.recording ? String(format: "● REC %.1f / 15 s", capture.labDiagnostics.elapsed) : "REAR CAMERA · FIXED SETUP")
                    .font(.caption.bold()).monospacedDigit().padding(8)
                    .background(.black.opacity(0.7), in: .capsule).padding(8)
            }
            .accessibilityLabel("Power shot camera with ball box and ground contact point")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if checklist.selected.isSetup {
                Text("Open the checklist, complete setup and choose a recording step.")
                    .font(.callout).foregroundStyle(.mint)
            } else {
                Text("\(checklist.selected.title) · \(checklist.reviewedCount(checklist.selected))/\(checklist.selected.target) reviewed")
                    .font(.headline).foregroundStyle(.mint)
                Text(checklist.selected.instruction).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Capture mode", selection: Binding(get: { capture.labEvidenceOnly }, set: { capture.setLabEvidenceOnly($0) })) {
                Text("AR estimates").tag(false)
                Text("Evidence only").tag(true)
            }.pickerStyle(.segmented).disabled(capture.recording || capture.finishing)
                .accessibilityIdentifier("lab-capture-mode")
            if capture.labEvidenceOnly {
                Text("Video + diagnostics · no live measurement").font(.headline)
                Text("Record even if grass, the ball or floor tracking cannot be found. Keep the phone fixed and film the reference marks. Missing geometry is flagged, never filled in.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ShotRollDistanceCard(state: capture.rollDisplay, compact: true)
            }
            Text(capture.labEvidenceOnly ? (capture.recording ? "Recording evidence · take the shot" : "No calibration needed to record evidence") :
                    pendingStart ? "WAIT · hold the ball still while the start is set" :
                    capture.recording && !capture.rollDisplay.isLive && capture.rollDisplay.trial > 0 ? "Measurement paused · video and raw observations still recording" :
                    capture.recording && capture.rollDisplay.trial > 0 ? "Start set · take the shot and keep the phone fixed" :
                    capture.groundStatus)
                .font(.callout.weight(.semibold)).foregroundStyle(pendingStart ? .orange : .mint)
            Text(String(format: "Camera %.0f fps · %@", capture.labDiagnostics.captureFPS,
                        capture.labDiagnostics.sample["measurement_gate"] ?? "waiting for ball"))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if capture.labDiagnostics.lastInvalidation != "none" {
                Text("Stopped measuring: " + capture.labDiagnostics.lastInvalidation)
                    .font(.caption).foregroundStyle(.orange)
            }
            if !capture.recording {
                Text(capture.labEvidenceOnly
                    ? "Keep the phone on a fixed support with the resting ball, whole path and reference marks in view. Record saves up to 15 seconds; no measurement start is needed."
                    : "Scan level ground, then fix the phone on a support. Keep the resting ball and full path in view. Rear camera, 0.3–3 m above the floor. Record saves up to 15 seconds and sets the start automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(capture.calibrationNeedsRetry ? "Recalibrate" : "Calibrate distance") { capture.beginRollCalibration() }
                        .disabled(!capture.canCalibrateRoll).accessibilityIdentifier("lab-calibrate")
                    Spacer()
                    Button("Trial setup") { showSetup = true }.disabled(capture.finishing)
                }.buttonStyle(.bordered)
                if capture.rollCalibration != nil || capture.calibrationNeedsRetry {
                    Button("Clear calibration · use raw AR") { capture.clearRollCalibration() }
                        .disabled(capture.finishing).accessibilityIdentifier("lab-clear-calibration")
                }
                Text(capture.calibrationStatus).font(.caption).foregroundStyle(.secondary)
                Text("Calibration is optional for recording. Calibrated tests also save the raw AR positions for comparison on the same shot.")
                    .font(.caption).foregroundStyle(.secondary)
                if capture.rollFloors.count > 1 {
                    Picker("Ground surface", selection: Binding(get: { capture.selectedRollFloorID ?? "" },
                        set: { capture.selectRollFloor($0) })) {
                        Text("Choose ground").tag("")
                        ForEach(capture.rollFloors) { floor in
                            Text(String(format: "Height %.2f m · %@", floor.cameraHeightM, String(floor.id.prefix(4)))).tag(floor.id)
                        }
                    }.disabled(capture.finishing)
                }
            }
            Text("Speed needs measured-spacing calibration. It is a smoothed ground-roll estimate (up to 21.6 km/h). Airborne shots are evidence captures; launch speed is not measured.")
                .font(.caption).foregroundStyle(.orange)
            DisclosureGroup("Live debug values") { diagnostics.padding(.top, 8) }
                .font(.callout).accessibilityIdentifier("lab-diagnostics")
            DisclosureGroup("Penalty / 11 m checklist") {
                Text("Confirm the actual mark-to-goal-line distance with a tape if possible. Set Trial setup → Penalty reference. Film the ball on the spot, the whole path and the goal-line crossing from a fixed side-on view. A low shot to the centre gives the cleanest 11 m check; corner and airborne paths are longer. Compare at line crossing, not the net. Calibrate on separate marks so 11 m stays an independent check. Capture 2 seconds still, the kick and the crossing. Review a first clip before repeating. With another phone, record the same shots at 120/240 fps or use radar for speed.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.callout)
            if let error = checklist.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var diagnostics: some View {
        let d = capture.labDiagnostics
        return VStack(alignment: .leading, spacing: 5) {
            metric("AR tracking", d.tracking)
            metric("Camera / exposure", String(format: "%.1f fps / %.2f ms", d.captureFPS, d.exposureMS))
            metric("Saved / writer drops", "\(d.savedFrames) / \(d.droppedFrames)")
            metric("Thermal", d.thermal)
            metric("Last invalidation", d.lastInvalidation)
            ForEach([
                ["model", "Detector"], ["confidence", "Confidence"], ["threshold", "Threshold"],
                ["detector_ms", "Inference ms"], ["observation_age_s", "Observation age s"],
                ["detector_sample_interval_s", "Detection interval s"], ["measurement_gate", "Measurement gate"],
                ["camera_height_m", "Camera height m"], ["radius_estimate_m", "Inferred radius m"],
                ["silhouette_edge_rms_px", "Sphere-fit RMS px"], ["inside_current_mapped_boundary", "Inside mapped floor"],
                ["tracker_step_m", "Attempted step m"], ["tracker_step_limit_m", "Allowed step m"],
                ["tracker_interval_s", "Step interval s"], ["camera_movement_m", "Camera moved m"],
                ["camera_angle_change_deg", "Camera angle change °"], ["rolling_speed_window_samples", "Speed samples"],
                ["rolling_speed_window_s", "Speed span s"], ["rolling_speed_fit_rms_m", "Speed-fit RMS m"],
                ["uncalibrated_distance_from_start_m", "Raw AR displacement m (unvalidated)"],
                ["raw_ground_projection_distance_m", "Active-floor projection m (unvalidated)"],
                ["raw_projection_speed_kmh", "Raw projection km/h (unvalidated)"]
            ], id: \.first) { item in metric(item[1], d.sample[item[0]] ?? "—") }
            Text("Raw projections continue after rejection for offline diagnosis. Airborne motion can produce large false values. All observations are saved in the evidence bundle.")
                .font(.caption2).foregroundStyle(.orange)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospaced().multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption2)
    }

    private var actions: some View {
        HStack {
            Button(capture.recording ? "Stop & save" : "Record test") {
                if capture.recording { capture.stop() }
                else {
                    capture.labReference = checklist.referenceForCapture(reference)
                    pendingStart = !capture.labEvidenceOnly; capture.begin()
                    if !capture.recording { pendingStart = false }
                }
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(capture.finishing || (!capture.recording &&
                    (!capture.canBeginRecording || checklist.selected.isSetup || !checklist.available)))
                .accessibilityIdentifier("lab-record")
            Button("Set start again") { capture.setRollStart(); pendingStart = false }
                .buttonStyle(.bordered)
                .disabled(capture.labEvidenceOnly || !capture.recording || !capture.rollDisplay.canSetStart || capture.finishing)
        }
    }

    private func armIfReady() {
        guard pendingStart, capture.recording, capture.rollDisplay.canSetStart else { return }
        capture.setRollStart()
        if capture.rollDisplay.trial > 0 { pendingStart = false }
    }
}

struct PowerShotReferenceFields: View {
    @Binding var reference: PowerShotFieldReference
    var beforeRecording = false
    private var penalty: Binding<PowerShotPenaltyReference> {
        Binding(get: { reference.penalty ?? PowerShotPenaltyReference() }, set: { reference.penalty = $0 })
    }
    var body: some View {
        Section("Observer labels") {
            Picker("Trial type", selection: $reference.kind) {
                Text("Ground roll").tag("ground_roll")
                Text("Ground shot").tag("ground_shot")
                Text("Airborne shot").tag("airborne_shot")
                Text("Stationary control").tag("stationary")
                Text("Tracking failure control").tag("failure_control")
            }
            TextField("Surface / lighting / phone support", text: $reference.surface)
            TextField("Notes (ball size, misses, start/end marks)", text: $reference.notes, axis: .vertical)
        }
        Section("Penalty reference") {
            Toggle("Penalty / goal-line check", isOn: Binding(get: { reference.penalty != nil },
                set: { reference.penalty = $0 ? PowerShotPenaltyReference() : nil }))
            if reference.penalty != nil {
                TextField("Spot to goal line (m)", text: penalty.goalLineDistanceM).keyboardType(.decimalPad)
                Picker("How was this distance obtained?", selection: penalty.distanceSource) {
                    Text("Regulation marking only (nominal)").tag("regulation_nominal")
                    Text("Tape measured on this pitch").tag("tape")
                    Text("Laser measured on this pitch").tag("laser")
                }
                Text("11 m is the forward ground distance to the goal line. It is not automatically the shot path or distance into the net. Keep this separate from calibration.")
                    .font(.caption).foregroundStyle(.secondary)
                if !beforeRecording {
                    TextField("Release time in video (s, optional)", text: penalty.releaseTimeS).keyboardType(.decimalPad)
                    TextField("Goal-line crossing time (s, optional)", text: penalty.crossingTimeS).keyboardType(.decimalPad)
                    TextField("Sideways offset from goal centre (m, optional)", text: penalty.lateralOffsetM)
                    TextField("Crossing height above ground (m, optional)", text: penalty.crossingHeightM).keyboardType(.decimalPad)
                    Text("Leave unknown values blank. Sideways offset can be signed; describe the camera view, crossing uncertainty and whether the ball was airborne in Notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !beforeRecording {
            Section("Independent references") {
                TextField("Actual endpoint distance (m)", text: $reference.endpointMetres).keyboardType(.decimalPad)
                Picker("Distance reference", selection: $reference.distanceMethod) {
                    Text("Unmeasured").tag("unmeasured")
                    Text("Tape / measured markers").tag("tape")
                    Text("Laser rangefinder").tag("laser")
                    Text("Apple Measure (comparison only)").tag("apple_measure")
                }
                TextField("Independent speed (km/h)", text: $reference.referenceSpeedKMH).keyboardType(.decimalPad)
                Picker("Speed reference", selection: $reference.speedMethod) {
                    Text("Unmeasured").tag("unmeasured")
                    Text("Radar (describe in notes)").tag("radar")
                    Text("Timed marker crossings (segment average)").tag("timed_markers")
                }
                Text("Distance means start to observed endpoint. Note whether the ball stopped or left the frame. Record reference timing and uncertainty in notes. Calibration marks and app estimates are not independent validation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PowerShotReferenceEditor: View {
    let directory: URL
    @State private var show = false
    @State private var reference = PowerShotFieldReference()
    @State private var error: String?
    @State private var saved = false
    var body: some View {
        VStack {
            Button("Add measured reference / field notes") {
                do { reference = try PowerShotFieldReference.load(from: directory); show = true; error = nil }
                catch { self.error = error.localizedDescription }
            }.buttonStyle(.bordered)
            if saved { Text("Field notes saved with this recording").font(.caption).foregroundStyle(.mint) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .sheet(isPresented: $show) {
            NavigationStack {
                Form {
                    PowerShotReferenceFields(reference: $reference)
                    if let error { Text(error).foregroundStyle(.orange) }
                }.navigationTitle("Field reference")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { show = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                do { try reference.save(to: directory); saved = true; show = false; error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
            }
        }
    }
}
#endif
