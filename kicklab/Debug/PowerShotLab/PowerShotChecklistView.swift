#if POWER_SHOT_DEBUG
import SwiftUI

struct PowerShotChecklistView: View {
    @ObservedObject var store: PowerShotChecklistStore
    var savedDirectory: URL?
    let useStep: (PowerShotChecklistStep) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text("\(store.completedCount) of \(store.requiredCount) core steps complete")
                        .font(.headline).accessibilityIdentifier("lab-checklist-progress")
                    ProgressView(value: Double(store.completedCount), total: Double(store.requiredCount))
                    Text("Tap a step → follow its instructions → record → replay and review. Progress stays on this phone. Saved footage alone does not mark a trial complete.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Session started \(store.session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Try each step") {
                    ForEach(Array(PowerShotChecklistStep.all.enumerated()), id: \.element.id) { index, step in
                        NavigationLink(value: step.id) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: store.complete(step) ? "checkmark.circle.fill" :
                                    store.session.gaps[step.id] != nil ? "exclamationmark.circle" : "circle")
                                    .foregroundStyle(store.complete(step) ? .mint : .orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(index + 1). \(step.title)").font(.headline)
                                    Text(step.isSetup ? (store.complete(step) ? "Setup checked" : "Setup check") :
                                        "\(store.reviewedCount(step)) / \(step.target) reviewed · \(store.clips(for: step).count) saved\(step.optional ? " · optional equipment" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let gap = store.session.gaps[step.id] {
                                        Text("Gap: \(gap)").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }.accessibilityIdentifier("lab-step-\(step.id)")
                    }
                }
                Section("Before you leave") {
                    if store.completedCount == store.requiredCount {
                        Label("Core capture checklist complete", systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
                    } else {
                        Text("Still needed: \(store.outstanding.filter { !$0.optional }.map(\.title).joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    if store.unreviewedCount > 0 { Text("\(store.unreviewedCount) saved take(s) still need replay review.").foregroundStyle(.orange) }
                    if !store.incomplete.isEmpty { Text("\(store.incomplete.count) capture(s) did not finish saving. Their partial files are kept and included in export as incomplete; repeat these trials.").foregroundStyle(.orange) }
                    if store.nominalPenaltyCount > 0 { Text("\(store.nominalPenaltyCount) penalty take(s) use nominal field markings. Tape-measure this pitch before leaving if possible, then update their references.").foregroundStyle(.orange) }
                    if !store.complete(PowerShotChecklistStep.all.last!) {
                        Text("Independent speed evidence is still missing. Without radar or matched external video, launch-speed accuracy remains unverified.").foregroundStyle(.secondary)
                    }
                    Text("Keep useful failures. Completion tracks collected evidence, not measurement accuracy. Review blur and missed crossings now; offline analysis cannot recover what was not filmed.")
                    Button {
                        Task {
                            exporting = true; exportError = nil
                            defer { exporting = false }
                            do { exportURL = try await store.export() }
                            catch { exportError = error.localizedDescription }
                        }
                    } label: {
                        if exporting { ProgressView("Preparing all evidence…") }
                        else { Label("Export checklist + all attempts", systemImage: "square.and.arrow.up") }
                    }.disabled(exporting || store.loading || !store.available || store.error != nil)
                        .accessibilityIdentifier("lab-export-checklist")
                    Toggle("I saved and checked a backup copy", isOn: Binding(get: { store.session.backupConfirmed }, set: { store.confirmBackup($0) }))
                    Text("Choose Save to Files or AirDrop, and keep any second-phone videos with matching labels. Opening Share does not confirm a backup.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let exportError { Text(exportError).foregroundStyle(.red) }
                }.font(.callout)
                if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Training checklist")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Camera") { dismiss() }.accessibilityIdentifier("lab-checklist-camera") } }
            .navigationDestination(for: String.self) { id in
                if let step = PowerShotChecklistStep.all.first(where: { $0.id == id }) {
                    PowerShotChecklistStepView(store: store, step: step, useStep: useStep, close: { dismiss() })
                }
            }
            .task {
                await store.reload()
                if let savedDirectory, let clip = store.clips.first(where: { $0.recording.directory == savedDirectory }),
                   let id = clip.reference.checklist?.stepID { path = [id] }
            }
            .refreshable { await store.reload() }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL { PowerShotChecklistShare(url: exportURL) }
            }
        }
    }
}

private struct PowerShotChecklistStepView: View {
    @ObservedObject var store: PowerShotChecklistStore
    let step: PowerShotChecklistStep
    let useStep: (PowerShotChecklistStep) -> Void
    let close: () -> Void
    @State private var gap = ""

    var body: some View {
        List {
            Section("Try this") {
                Text(step.instruction).font(.body)
                if !step.isSetup {
                    Text("Target: \(step.target) separate reviewed clips. One shot per recording.").font(.headline)
                    Text("\(store.reviewedCount(step)) / \(step.target) complete · \(store.clips(for: step).count) saved")
                        .accessibilityIdentifier("lab-step-progress")
                }
                Button(step.isSetup ? "Open camera for this setup" :
                    store.complete(step) ? "Record another take" : "Try this · open camera") {
                    store.select(step)
                    useStep(step)
                }.buttonStyle(.borderedProminent).disabled(!store.available)
                    .accessibilityIdentifier("lab-use-step")
                if store.complete(step), let next = store.outstanding.first(where: { $0.id != step.id }) {
                    Button("Next step: \(next.title)") {
                        store.select(next); useStep(next)
                    }.accessibilityIdentifier("lab-next-step")
                }
            }
            Section(step.isSetup ? "Check when finished" : "Check each replay") {
                Text(step.review)
                if step.isSetup {
                    Button(store.complete(step) ? "Checked ✓" : "I completed this setup") { store.confirmSetup(step) }
                        .disabled(!store.available).accessibilityIdentifier("lab-complete-setup")
                    if step.id == "calibration" {
                        Text("If calibration could not be completed, enter a gap below and continue with evidence recording. Do not mark it checked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !step.isSetup {
                Section("Saved attempts · tap to review") {
                    if store.clips(for: step).isEmpty { Text("No saved attempts for this step yet.").foregroundStyle(.secondary) }
                    ForEach(store.clips(for: step)) { clip in
                        NavigationLink {
                            PowerShotChecklistReviewView(store: store, step: step, clip: clip)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(clip.recording.date.formatted(date: .omitted, time: .standard)).font(.headline)
                                Text(clip.missingEvidence(for: step) ?? "Reviewed · counts toward this step")
                                    .font(.caption).foregroundStyle(clip.missingEvidence(for: step) == nil ? .mint : .orange)
                            }
                        }.accessibilityIdentifier("lab-review-\(clip.id)")
                    }
                }
            }
            Section("Cannot finish this step?") {
                TextField("Reason / missing equipment", text: $gap, axis: .vertical)
                    .accessibilityIdentifier("lab-step-gap")
                Button("Save gap / clear if blank") { store.setGap(gap, for: step) }
                    .disabled(!store.available).accessibilityIdentifier("lab-save-gap")
                Text("A gap stays visible in the final checklist; it does not count as completed evidence. Continue with any other step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(step.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Camera", action: close).accessibilityIdentifier("lab-checklist-camera") } }
        .onAppear { gap = store.session.gaps[step.id] ?? "" }
    }
}

private struct PowerShotChecklistReviewView: View {
    @ObservedObject var store: PowerShotChecklistStore
    let step: PowerShotChecklistStep
    let clip: PowerShotChecklistClip
    @Environment(\.dismiss) private var dismiss
    @State private var reference = PowerShotFieldReference()
    @State private var review = PowerShotChecklistReview()
    @State private var openedReplay = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section("1. Watch the saved video") {
                NavigationLink {
                    ShotRecordingReplayView(recording: clip.recording, allowsFieldNotes: false)
                        .onAppear { openedReplay = true }
                } label: { Label("Replay this take", systemImage: "play.circle.fill") }
                Text(step.review).font(.callout)
            }
            Section("2. Review this attempt") {
                Picker("Result", selection: $review.disposition) {
                    Text("Usable evidence").tag("usable")
                    Text("Needs another take").tag("retake")
                }.pickerStyle(.segmented)
                if review.disposition == "usable" {
                    Toggle("I watched the replay and checked the requirement above", isOn: $review.visibilityConfirmed)
                        .disabled(!openedReplay && reference.checklistReview == nil)
                    if !openedReplay && reference.checklistReview == nil { Text("Open Replay this take first.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    TextField("What was missing? (blur, crossing, framing…)", text: $review.reason, axis: .vertical)
                    Text("The original video and diagnostics stay saved. This take will not count toward the target.").font(.caption).foregroundStyle(.secondary)
                }
            }
            PowerShotReferenceFields(reference: $reference)
            Section {
                let candidate = PowerShotChecklistClip(recording: clip.recording, reference: reviewedReference)
                if let missing = candidate.missingEvidence(for: step) { Text(missing).foregroundStyle(.orange) }
                else { Text("This reviewed take will count toward the checklist. Accuracy still needs analysis.").foregroundStyle(.mint) }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Save review") {
                    Task {
                        do {
                            try reviewedReference.save(to: clip.recording.directory)
                            store.confirmBackup(false)
                            await store.reload()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(!loaded || (review.disposition == "usable" && !review.visibilityConfirmed) ||
                    (review.disposition == "retake" && review.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("lab-save-review")
            }
        }
        .navigationTitle("Review attempt").navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            do {
                reference = try PowerShotFieldReference.load(from: clip.recording.directory)
                if !loaded { review = reference.checklistReview ?? PowerShotChecklistReview() }
                loaded = true
            } catch { self.error = error.localizedDescription }
        }
    }
    private var reviewedReference: PowerShotFieldReference {
        var value = reference, result = review
        result.reviewedAt = Date(); value.checklistReview = result
        return value
    }
}

private struct PowerShotChecklistShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
