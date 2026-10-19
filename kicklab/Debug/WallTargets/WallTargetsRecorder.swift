#if DEBUG
import AVFoundation
import Foundation

/// Carries JSON-ready metadata (property-list values only) onto the camera queue.
nonisolated struct WallTargetsSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Saves what the wall-targets camera saw, for offline review with
/// benchmarks/wall-targets/tools: video.mov, detections.csv (the columns of
/// tools/detect.swift, one row per written video frame, normalised to the
/// frame) and session.json (corners, frame size, style and the hits the live
/// rules reported). Folders live in Documents/WallTargets, visible in Files.
///
/// Everything is written as it happens: the movie in one-second fragments,
/// detections in small batches, and session.json after each batch and hit.
/// An app killed mid-recording (a reinstall, a crash) keeps all but the last
/// second; without this, a QuickTime file has no index and will not play.
/// Used only on the camera queue.
nonisolated final class WallTargetsRecorder: @unchecked Sendable {
    struct Completion: Sendable {
        let folder: URL
        let error: String?
        var succeeded: Bool { error == nil }
    }
    let folder: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var metadata: [String: Any]
    private let detections: FileHandle
    private let resources: FileHandle
    private var resourceSampleCount = 0
    private var peakMemoryMiB: Double?
    private var worstThermalState = -1
    private var resourceLoggingError: String?
    private var pendingRows: [String] = []
    private var frames = 0
    private var impacts: [[String: Any]] = []
    private var start: Double?
    private var duration = 0.0
    private var phase = "setup"
    private var referenceBox = 0
    private var phases: [[String: Any]] = []
    private var references: [[String: Any]] = []
    private var decisions: [[String: Any]] = []
    private var alignments: [[String: Any]] = []
    private var mappingChecks: [[String: Any]] = []
    private var feedbackEvents: [[String: Any]] = []
    private var feedbackDeliveries: [[String: Any]] = []

    private static let flushEvery = 30

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallTargets", isDirectory: true)
    }

    init(size: CGSize, metadata: [String: Any], root: URL = WallTargetsRecorder.root) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = formatter.string(from: Date())
        let preferred = root.appendingPathComponent(name, isDirectory: true)
        folder = FileManager.default.fileExists(atPath: preferred.path)
            ? root.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true) : preferred
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("video.mov"), fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "WallTargets", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Cannot start recording"])
        }
        let csv = folder.appendingPathComponent("detections.csv")
        FileManager.default.createFile(atPath: csv.path, contents: Data("frame,t,ball_score,bx,by,bw,bh,person_score,px,py,pw,ph,hand_state,phase,reference_box,ball_source,alignment_state,alignment_revision,alignment_epoch,retain_evidence,can_score,lens_position,adjusting_focus,inference_ran\n".utf8))
        detections = try FileHandle(forWritingTo: csv)
        detections.seekToEndOfFile()
        let resourceURL = folder.appendingPathComponent("resources.jsonl")
        FileManager.default.createFile(atPath: resourceURL.path, contents: nil)
        resources = try FileHandle(forWritingTo: resourceURL)
        self.metadata = metadata
        writeSession(status: "recording")
    }

    /// A frame the writer cannot take gets no CSV row, so rows stay aligned with video frames.
    func append(_ pixels: CVPixelBuffer, at time: CMTime, ball: Detection?, person: Detection?, hand: WallHandState, source: Int = 0,
                alignment: WallBoardAlignment.Update? = nil, retainEvidence: Bool = false, canScore: Bool = false,
                lensPosition: Double? = nil, adjustingFocus: Bool = false, inferenceRan: Bool? = nil) {
        if start == nil {
            writer.startSession(atSourceTime: time)
            start = time.seconds
        }
        guard let start, input.isReadyForMoreMediaData, adaptor.append(pixels, withPresentationTime: time) else { return }
        let values: [Double] = ball.map { [$0.score, $0.x, $0.y, $0.width, $0.height] } ?? [0, 0, 0, 0, 0]
        duration = time.seconds - start
        var fields = [String(frames), String(format: "%.5f", duration)]
        fields += values.map { String(format: "%.5f", $0) }
        fields += (person.map { [$0.score, $0.x, $0.y, $0.width, $0.height] } ?? [0, 0, 0, 0, 0]).map { String(format: "%.5f", $0) }
        fields += [String(hand.rawValue), String(["setup": 0, "reference": 1, "countdown": 2, "playing": 3, "mapping_check": 4][phase] ?? 0), String(referenceBox)]
        fields += [String(source)]
        let states: [WallBoardAlignment.Status] = [.checking, .ready, .obscured, .shifted, .referenceRequired]
        fields += [String(alignment.flatMap { states.firstIndex(of: $0.status) } ?? -1), String(alignment?.revision ?? -1)]
        fields += [String(alignment?.evidenceEpoch ?? -1), retainEvidence ? "1" : "0", canScore ? "1" : "0",
                   String(format: "%.5f", lensPosition ?? -1), adjustingFocus ? "1" : "0",
                   inferenceRan.map { $0 ? "1" : "0" } ?? "-1"]
        pendingRows.append(fields.joined(separator: ","))
        frames += 1
        if pendingRows.count >= Self.flushEvery { flush() }
    }

    /// Keep unsuccessful attempts too, so a later retry cannot erase the diagnosis.
    func noteMapping(_ report: WallMappingCheck.Report) {
        guard let data = try? JSONEncoder().encode(report),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        json["t"] = duration
        json["version"] = "fifteen-points-two-blinks-v1"
        json["maximumErrorPixels"] = report.maximumErrorPixels
        json["maximumErrorCells"] = report.maximumErrorCells
        mappingChecks.append(json)
        updateMetadata(["mappingCheck": json, "mappingChecks": mappingChecks])
    }

    /// `impact.t` is on the capture clock; stored relative to the first frame.
    func note(_ impact: WallImpactDetector.Impact) {
        guard let start else { return }
        impacts.append(["t": impact.t - start, "box": impact.box ?? NSNull(), "u": impact.u, "v": impact.v,
                        "x": impact.x, "y": impact.y, "d": impact.d, "turn": impact.turn, "borderline": impact.borderline])
        writeSession(status: "recording")
    }

    /// Timestamp of the camera frame that supplied the decision evidence. This
    /// is not the wall-clock time of dispatch, playback or projected feedback.
    /// Preview entries are tentative observations, never training hit labels.
    func noteFeedback(_ impact: WallImpactDetector.Impact, at time: Double, kind: String) {
        guard let start else { return }
        feedbackEvents.append(["contactTime": impact.t - start, "reported": time - start,
            "kind": kind, "u": impact.u, "v": impact.v,
            "box": impact.box ?? NSNull(), "borderline": impact.borderline])
    }

    /// Actual host-clock stages, relative to the first video frame. A callback
    /// completing means the model and sound request were handled, not that the
    /// projector rendered the frame or the audio route played it audibly.
    func noteFeedbackDelivery(_ impact: WallImpactDetector.Impact, evidenceFrame: Double,
                              decisionReady: Double, mainActorReceived: Double,
                              callbackCompleted: Double, accepted: Bool) {
        guard let start else { return }
        feedbackDeliveries.append([
            "contactTime": impact.t - start, "evidenceFrameTime": evidenceFrame - start,
            "decisionReadyTime": decisionReady - start, "mainActorReceivedTime": mainActorReceived - start,
            "callbackCompletedTime": callbackCompleted - start, "accepted": accepted,
            "box": impact.box ?? NSNull(), "borderline": impact.borderline])
    }

    func updateMetadata(_ extra: [String: Any]) {
        metadata.merge(extra) { _, new in new }
        writeSession(status: "recording")
    }

    /// Append a bounded-rate resource history; do not retain a growing sample
    /// array in memory or change the frame-aligned detection CSV schema.
    func noteResources(_ sample: WallRuntimeSample) {
        guard let start, sample.uptime >= start, resourceLoggingError == nil else { return }
        do {
            let encoded = try JSONEncoder().encode(sample)
            var row = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            row.removeValue(forKey: "uptime")
            row["t"] = sample.uptime - start
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try resources.write(contentsOf: data + Data([0x0A]))
            resourceSampleCount += 1
            if let memory = sample.memoryMiB { peakMemoryMiB = max(peakMemoryMiB ?? memory, memory) }
            worstThermalState = max(worstThermalState, sample.thermalState)
        } catch { resourceLoggingError = error.localizedDescription }
    }

    func noteDecisions(_ items: [WallImpactDetector.Decision]) {
        guard let start else { return }
        decisions += items.map { ["t": $0.t - start, "x": $0.x, "y": $0.y, "d": $0.d, "reason": $0.reason] }
        if decisions.count > 5000 { decisions.removeFirst(decisions.count - 5000) }
    }

    func noteAlignment(_ update: WallBoardAlignment.Update, at time: Double) {
        guard let start else { return }
        alignments.append(["t": time - start, "state": update.status.rawValue, "revision": update.revision,
                           "evidenceEpoch": update.evidenceEpoch,
                           "cornersNormalised": update.corners.map { [Double($0.x), Double($0.y)] }])
    }

    func setPhase(_ phase: String, box: Int = 0) {
        self.phase = phase; referenceBox = box
        phases.append(["t": duration, "phase": phase, "box": box])
        writeSession(status: "recording")
    }

    func noteReference(box: Int, diameter: Double, at time: Double) {
        references.append(["box": box, "diameterNormalised": diameter, "t": time - (start ?? time)])
        writeSession(status: "recording")
    }

    /// `extra` (for example the round clear times) is merged into session.json.
    func finish(extra: [String: Any]) async -> Completion {
        flush()
        try? detections.close()
        try? resources.close()
        input.markAsFinished()
        await writer.finishWriting()
        var error = writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "Video could not be finalized")
        if !writeSession(status: error.map { "failed: \($0)" } ?? "completed", extra: extra) {
            error = "Video finished, but session data could not be saved"
        }
        // Record tapped straight back to Stop: nothing to review, so leave no empty session behind.
        if frames == 0 { try? FileManager.default.removeItem(at: folder) }
        return Completion(folder: folder, error: frames == 0 ? "No video frames were recorded" : error)
    }

    private func flush() {
        guard !pendingRows.isEmpty else { return }
        detections.write(Data((pendingRows.joined(separator: "\n") + "\n").utf8))
        pendingRows = []
        writeSession(status: "recording")
    }

    @discardableResult
    private func writeSession(status: String, extra: [String: Any] = [:]) -> Bool {
        var session = metadata.merging(extra) { _, new in new }
        session["frames"] = frames
        session["duration"] = duration
        session["impacts"] = impacts
        session["feedbackEvents"] = feedbackEvents
        session["feedbackDeliveries"] = feedbackDeliveries
        session["resourceLog"] = "resources.jsonl"
        session["resourceSampleCount"] = resourceSampleCount
        session["sampledPeakMemoryMiB"] = peakMemoryMiB as Any? ?? NSNull()
        session["worstThermalState"] = worstThermalState
        session["resourceLoggingError"] = resourceLoggingError as Any? ?? NSNull()
        session["phases"] = phases
        session["referenceSamples"] = references
        session["contactDecisions"] = decisions
        session["alignmentEvents"] = alignments
        session["status"] = status
        do {
            let data = try JSONSerialization.data(withJSONObject: session, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
            return true
        } catch { return false }
    }
}
#endif
