#if POWER_SHOT_DEBUG
import Foundation
import Combine

nonisolated struct PowerShotChecklistStep: Identifiable, Codable {
    let id: String
    let title: String
    let instruction: String
    let review: String
    let target: Int
    let kind: String
    var reference = "none"
    var optional = false
    var isSetup: Bool { target == 0 }

    static let all: [Self] = [
        .init(id: "setup", title: "Set up the field", instruction: "Fix the phone in landscape, safely beside the shot lane. Frame the resting ball, full path and goal line. Note the surface, light, support and ball size in Trial setup. Tape-measure separate 1 m, 2 m and 5 m check marks and the penalty baseline if possible. Keep calibration marks separate. Each clip allows 15 seconds.", review: "I checked the framing and noted which distances are actually measured. If equipment is missing, record it as a gap below.", target: 0, kind: ""),
        .init(id: "calibration", title: "Calibrate on separate marks", instruction: "Return to the camera and use Calibrate distance with two separately measured marks. Do not use the penalty baseline for calibration. Calibrated clips also save raw AR geometry for comparison. If calibration fails, record the reason here and use Evidence only; keep collecting footage.", review: "I completed calibration using separate measured marks. This confirms setup, not accuracy; recalibrate if the phone moves.", target: 0, kind: ""),
        .init(id: "stationary", title: "Keep the ball still", instruction: "Record two clips of a stationary ball for 5–8 seconds. Keep the phone fixed. Try one close position and one farther away. This checks drift and false motion.", review: "The ball and camera stayed still and the ball is clearly visible for at least 5 seconds.", target: 2, kind: "stationary"),
        .init(id: "roll_1m", title: "Slow rolls · 1 m check", instruction: "Make three separate slow ground rolls past the independently measured 1 m mark. Start with 2 seconds still. Keep the start, crossing and endpoint visible. The target mark is not automatically the actual endpoint.", review: "The start and 1 m crossing are visible. Enter the measured start-to-endpoint distance and describe the endpoint or marker crossing in notes.", target: 3, kind: "ground_roll", reference: "distance"),
        .init(id: "roll_2m", title: "Slow rolls · 2 m check", instruction: "Make three separate slow rolls past the independent 2 m check mark, away from the calibration marks. Keep the phone fixed and record 2 seconds still before each roll.", review: "The start and 2 m crossing are visible. Add the actual measured endpoint distance and describe the endpoint in notes.", target: 3, kind: "ground_roll", reference: "distance"),
        .init(id: "roll_5m", title: "Slow rolls · 5 m check", instruction: "Make three separate ground rolls past the measured 5 m mark. Keep the complete path in frame and continue filming beyond the crossing. Save rejected measurements too.", review: "The start and 5 m crossing are visible. Add the actual measured endpoint distance and describe the endpoint in notes.", target: 3, kind: "ground_roll", reference: "distance"),
        .init(id: "ground_fast", title: "Faster ground shots", instruction: "Record three faster shots that stay on the ground, using independently measured marks. Keep 2 seconds of still lead-in. Keep filming if the live measurement stops; its failure is evidence.", review: "The ball stayed on the ground; the start and endpoint or measured crossing are visible. Add the actual measured endpoint distance and describe it in notes.", target: 3, kind: "ground_shot", reference: "distance"),
        .init(id: "penalty_low", title: "Penalty · low central shots", instruction: "Take three low shots from the penalty mark toward the goal centre. Film the resting ball, whole path and goal-line crossing from a fixed side view. Enter the actual spot-to-line baseline or explicitly label 11 m as nominal. Compare at the line, not the net.", review: "The resting ball and goal-line crossing are visible. The penalty baseline and its source are recorded. Note any sideways offset; do not enter 11 m as the final net distance.", target: 3, kind: "ground_shot", reference: "penalty"),
        .init(id: "penalty_air", title: "Penalty · airborne shots", instruction: "Record three airborne penalty shots separately. Show launch, flight and goal-line crossing, plus landing if visible. Keep the baseline labelled measured or nominal. Airborne path length is not 11 m; this app does not yet measure launch speed.", review: "Launch, flight and goal-line crossing are visible. Note airborne height, sideways offset and any uncertainty; leave unknown values blank.", target: 3, kind: "airborne_shot", reference: "penalty"),
        .init(id: "failure", title: "Capture tracking failures", instruction: "Make two controls: briefly hide a stationary ball and uncover it; then roll it out of frame. Keep the camera fixed. Save the whole event, even when no distance appears. These are useful failures, not takes to delete.", review: "The intended occlusion or exit and its timing are visible. Describe which control you performed in notes.", target: 2, kind: "failure_control", reference: "notes"),
        .init(id: "moved_setup", title: "Move, recalibrate and repeat", instruction: "Move the support to a different fixed view. Recalibrate on separate marks, then record two slow rolls across the independent 2 m mark. If recalibration fails, use Evidence only and note it.", review: "The changed setup, start and measured crossing are visible. Add the actual measured endpoint and note whether recalibration worked.", target: 2, kind: "ground_roll", reference: "distance"),
        .init(id: "speed_reference", title: "Independent speed reference", instruction: "If you have radar or another phone, capture two matched shots. For the second phone use high-frame-rate video with two measured crossing marks. Keep the separate files and identify matching clips in notes. Record radar placement or marker spacing, timing and uncertainty. Segment average is not launch speed.", review: "An independent speed and method are entered. Notes identify the matching external file and reference definition. Never copy this app’s displayed speed as the reference.", target: 2, kind: "ground_shot", reference: "speed", optional: true)
    ]
}

nonisolated struct PowerShotChecklistLink: Codable, Equatable {
    var sessionID: UUID
    var stepID: String
    var attemptID = UUID()
    var protocolVersion = 1
}

nonisolated struct PowerShotChecklistReview: Codable, Equatable {
    var disposition = "usable"
    var visibilityConfirmed = false
    var reason = ""
    var reviewedAt = Date()
}

nonisolated struct PowerShotChecklistSession: Codable {
    var schema = "kicklab.power-shot-checklist.v1"
    var id = UUID()
    var startedAt = Date()
    var selectedStepID = "setup"
    var completedSetup: Set<String> = []
    var gaps: [String: String] = [:]
    var backupConfirmed = false
    var setupReference: PowerShotFieldReference?
}

nonisolated struct PowerShotChecklistClip: Identifiable, Sendable {
    let recording: ShotRecording
    let reference: PowerShotFieldReference
    var id: String { recording.id }

    /// These are human-reviewed collection criteria, never an accuracy verdict.
    func missingEvidence(for step: PowerShotChecklistStep) -> String? {
        guard let review = reference.checklistReview else { return "Replay and review this take" }
        guard review.disposition == "usable" else { return "Needs another take: \(review.reason)" }
        guard review.visibilityConfirmed else { return "Confirm the replay meets this step’s visibility check" }
        if let error = reference.validationError { return error }
        switch step.reference {
        case "distance":
            guard let distance = Double(reference.endpointMetres.replacingOccurrences(of: ",", with: ".")), distance > 0,
                  ["tape", "laser"].contains(reference.distanceMethod), !reference.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return "Add an independently measured endpoint and notes identifying it" }
        case "penalty":
            guard reference.penalty != nil else { return "Add the penalty baseline and its source" }
        case "notes":
            guard !reference.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Describe the control in notes" }
        case "speed":
            guard let speed = Double(reference.referenceSpeedKMH.replacingOccurrences(of: ",", with: ".")), speed > 0,
                  ["radar", "timed_markers"].contains(reference.speedMethod), !reference.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return "Add independent speed, method and matching external reference details" }
        default: break
        }
        return nil
    }
}

@MainActor
final class PowerShotChecklistStore: ObservableObject {
    @Published private(set) var session: PowerShotChecklistSession
    @Published private(set) var clips: [PowerShotChecklistClip] = []
    @Published private(set) var incomplete: [URL] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private let sessionURL: URL
    private let recordingsRoot: URL
    private var readable = true
    var available: Bool { readable }

    init(sessionURL: URL? = nil, recordingsRoot: URL = ShotRecordingStore.root) {
        self.sessionURL = sessionURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerShotChecklist/session.json")
        self.recordingsRoot = recordingsRoot
        do {
            if FileManager.default.fileExists(atPath: self.sessionURL.path) {
                session = try JSONDecoder().decode(PowerShotChecklistSession.self, from: Data(contentsOf: self.sessionURL))
            } else {
                let fresh = PowerShotChecklistSession()
                try Self.write(fresh, to: self.sessionURL)
                session = fresh
            }
        } catch {
            session = PowerShotChecklistSession(); readable = false
            self.error = "Checklist could not be loaded. Existing progress was kept: \(error.localizedDescription)"
        }
    }

    var selected: PowerShotChecklistStep {
        PowerShotChecklistStep.all.first { $0.id == session.selectedStepID } ?? PowerShotChecklistStep.all[0]
    }
    func clips(for step: PowerShotChecklistStep) -> [PowerShotChecklistClip] { clips.filter { $0.reference.checklist?.stepID == step.id } }
    func reviewedCount(_ step: PowerShotChecklistStep) -> Int { clips(for: step).filter { $0.missingEvidence(for: step) == nil }.count }
    func complete(_ step: PowerShotChecklistStep) -> Bool {
        guard session.gaps[step.id] == nil else { return false }
        return step.isSetup ? session.completedSetup.contains(step.id) : reviewedCount(step) >= step.target
    }
    var completedCount: Int { PowerShotChecklistStep.all.filter { !$0.optional && complete($0) }.count }
    var requiredCount: Int { PowerShotChecklistStep.all.filter { !$0.optional }.count }
    var outstanding: [PowerShotChecklistStep] { PowerShotChecklistStep.all.filter { !complete($0) } }
    var nominalPenaltyCount: Int { clips.filter { $0.reference.penalty?.distanceSource == "regulation_nominal" }.count }
    var unreviewedCount: Int { clips.filter { $0.reference.checklistReview == nil }.count }

    nonisolated private static func write(_ session: PowerShotChecklistSession, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: url, options: .atomic)
    }
    private func update(_ edit: (inout PowerShotChecklistSession) -> Void) {
        guard readable else { return }
        var copy = session; copy.backupConfirmed = false; edit(&copy)
        do { try Self.write(copy, to: sessionURL); session = copy; error = nil }
        catch { self.error = "Progress was not saved: \(error.localizedDescription)" }
    }
    func select(_ step: PowerShotChecklistStep) { update { $0.selectedStepID = step.id } }
    func confirmSetup(_ step: PowerShotChecklistStep) {
        guard step.isSetup else { return }
        update { value in
            value.completedSetup.insert(step.id); value.gaps.removeValue(forKey: step.id)
            if let next = PowerShotChecklistStep.all.first(where: { $0.id != step.id && !complete($0) && $0.id != "setup" }) {
                value.selectedStepID = next.id
            }
        }
    }
    func setGap(_ text: String, for step: PowerShotChecklistStep) {
        update {
            let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.isEmpty { $0.gaps.removeValue(forKey: step.id) }
            else { $0.gaps[step.id] = reason; $0.completedSetup.remove(step.id) }
        }
    }
    func confirmBackup(_ value: Bool) { update { $0.backupConfirmed = value } }
    func saveSetupReference(_ reference: PowerShotFieldReference) { update { $0.setupReference = reference } }

    func referenceForCapture(_ base: PowerShotFieldReference) -> PowerShotFieldReference {
        var result = base
        result.checklistReview = nil
        result.endpointMetres = ""; result.distanceMethod = "unmeasured"
        result.referenceSpeedKMH = ""; result.speedMethod = "unmeasured"
        if !selected.isSetup && readable {
            result.kind = selected.kind
            result.checklist = PowerShotChecklistLink(sessionID: session.id, stepID: selected.id)
            if selected.reference == "penalty" {
                var penalty = result.penalty ?? PowerShotPenaltyReference()
                penalty.releaseTimeS = ""; penalty.crossingTimeS = ""; penalty.lateralOffsetM = ""; penalty.crossingHeightM = ""
                result.penalty = penalty
            } else { result.penalty = nil }
        } else { result.checklist = nil }
        return result
    }

    func reload() async {
        guard readable, !loading else { return }
        loading = true
        defer { loading = false }
        let root = recordingsRoot, sessionID = session.id
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let library = try ShotRecordingStore.load(root: root)
                var clips: [PowerShotChecklistClip] = []
                for recording in library.recordings {
                    let reference = try PowerShotFieldReference.load(from: recording.directory)
                    if reference.checklist?.sessionID == sessionID { clips.append(.init(recording: recording, reference: reference)) }
                }
                let completeIDs = Set(library.recordings.map(\.id))
                let folders = FileManager.default.fileExists(atPath: root.path)
                    ? try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) : []
                let incomplete = folders.filter { folder in
                    !completeIDs.contains(folder.lastPathComponent) &&
                    (try? PowerShotFieldReference.load(from: folder).checklist?.sessionID) == sessionID
                }
                return (clips, incomplete)
            }.value
            clips = result.0; incomplete = result.1; error = nil
        } catch {
            clips = []; incomplete = []
            self.error = "Could not refresh checklist evidence: \(error.localizedDescription)"
        }
    }

    /// Export every attempt, including retakes and clearly labelled unfinished files.
    func export() async throws -> URL {
        guard readable, error == nil else { throw ShotRecordingStore.StoreError.incomplete }
        let session = session, clips = clips, incomplete = incomplete
        let plan = PowerShotChecklistStep.all
        return try await Task.detached(priority: .userInitiated) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let folder = temporary.appendingPathComponent("Power-Shot-Checklist")
            var succeeded = false
            defer { try? FileManager.default.removeItem(at: succeeded ? folder : temporary) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.write(session, to: folder.appendingPathComponent("checklist-session.json"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(plan).write(to: folder.appendingPathComponent("protocol.json"))
            for clip in clips { _ = try ShotRecordingStore.export(clip.recording, to: folder.appendingPathComponent("Recordings")) }
            if !incomplete.isEmpty {
                let failed = folder.appendingPathComponent("Incomplete-unverified")
                try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
                for source in incomplete { try FileManager.default.copyItem(at: source, to: failed.appendingPathComponent(source.lastPathComponent)) }
            }
            let summary: [String: Any] = ["session_id": session.id.uuidString,
                "note": "Checklist completion means human-reviewed evidence collection, not validated accuracy. Recording ZIPs verify original sensor hashes; Incomplete-unverified folders did not finish saving.",
                "incomplete_recordings": incomplete.map(\.lastPathComponent),
                "steps": plan.map { step -> [String: Any] in
                    let matching = clips.filter { $0.reference.checklist?.stepID == step.id }
                    return ["id": step.id, "target": step.target, "optional": step.optional,
                        "setup_confirmed": session.completedSetup.contains(step.id), "gap": session.gaps[step.id] ?? "",
                        "reviewed_count": matching.filter { $0.missingEvidence(for: step) == nil }.count,
                        "recordings": matching.map { ["id": $0.id, "missing_evidence": $0.missingEvidence(for: step) ?? ""] }]
                }]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("evidence-summary.json"))
            let destination = temporary.appendingPathComponent("Power-Shot-Checklist-\(session.id.uuidString.prefix(8)).zip")
            var coordinationError: NSError?, copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { snapshot in
                do { try FileManager.default.copyItem(at: snapshot, to: destination) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError as NSError? { throw error }
            guard FileManager.default.fileExists(atPath: destination.path) else { throw ShotRecordingStore.StoreError.incomplete }
            succeeded = true
            return destination
        }.value
    }
}
#endif
