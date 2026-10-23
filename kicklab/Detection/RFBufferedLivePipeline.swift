import AVFoundation
import CoreImage
import CoreML
import Foundation
import UIKit

nonisolated struct PacedFrame {
    let index: Int
    let time: Double
    let due: Double
    let image: CIImage
    let pixels: CVPixelBuffer
    var identity: RecordedFrameIdentity? = nil
    var recordingStart: Double = 0
    var captureDrops: Int = 0
    var size: CGSize { image.extent.size }
    /// Every consumer of this exposure must use the same quantized clock.
    var timestampMs: Int { Int(time * 1000) }
}
nonisolated private func candidates(_ prediction: MLFeatureProvider, size: CGSize) throws -> [AsyncBallCandidate] {
    guard let scores = prediction.featureValue(for: "linear_122")?.multiArrayValue,
          let boxes = prediction.featureValue(for: "concat_2")?.multiArrayValue,
          scores.shape.map(\.intValue) == [1,100,91], boxes.shape.map(\.intValue) == [1,100,4] else {
        throw NSError(domain: "RF output contract", code: 1)
    }
    let ss = scores.strides.map(\.intValue), bs = boxes.strides.map(\.intValue)
    return (0..<100).compactMap { q in
        let score = 1/(1+exp(-number(scores, q*ss[1]+37*ss[2])))
        let b = (0..<4).map { number(boxes, q*bs[1]+$0*bs[2]) }
        guard score.isFinite, score >= 0.4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0 else { return nil }
        let rect = CGRect(x: (b[0]-b[2]/2)*size.width, y: (b[1]-b[3]/2)*size.height,
                          width: b[2]*size.width, height: b[3]*size.height)
            .intersection(CGRect(origin: .zero, size: size))
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return AsyncBallCandidate(query: q, hit: FollowHit(rect: rect, score: score))
    }
}
nonisolated struct RFReply {
    let frame: PacedFrame
    let found: FrameDetections
    let selected: AsyncBallCandidate?
    let reason: String
    let candidateCount: Int
    let candidates: [AsyncBallCandidate]
    let started: Double
    let preparationMS: Double
    let predictionMS: Double
    let completed: Double
    let error: String?
}

// The worker owns its model/context during inference. Exactly one job OR unread
// reply is retained; a slow consumer cannot create an inference queue.
nonisolated final class RFWorker {
    private let queue = DispatchQueue(label: "rf.async.diagnostic", qos: .userInitiated)
    private let lock = NSLock()
    private var occupied = false
    private var reply: RFReply?
    private var priorityRequested = false
    private var activeInferences = 0
    private var maximumActiveInferences = 0
    private var inferenceCounts: [String: Int] = [:]
    private var recentInferenceSeconds: [Double] = []
    var recheckBudget: Double {
        lock.lock(); defer { lock.unlock() }
        return ContactBacklogPolicy().rfBudget(recentMaximum: recentInferenceSeconds.max() ?? 0.120)
    }
    func recheckIfIdle(_ frame: PacedFrame, hint: FollowHit, latestStart: Double,
                       admit: () -> Bool) -> (RFReply?, String) {
        lock.lock()
        // An unread completed reply is safe; a queued or active normal job is not.
        guard !priorityRequested, activeInferences == 0, !occupied || reply != nil else {
            lock.unlock(); return (nil, "rf_worker_busy")
        }
        priorityRequested = true; lock.unlock()
        defer { lock.lock(); priorityRequested = false; lock.unlock() }
        return queue.sync {
            guard uptime() <= latestStart, thermal() < 3 else { return (nil, "worker_deadline_or_thermal_limit") }
            guard admit() else { return (nil, "backlog_limit_at_start") }
            return (infer(frame, hint: hint, purpose: "contact"), "idle_worker_inference")
        }
    }
    var statistics: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["active": activeInferences, "maximum_active": maximumActiveInferences,
            "regular": inferenceCounts["regular", default: 0],
            "warmup": inferenceCounts["warmup", default: 0],
            "contact": inferenceCounts["contact", default: 0], "model_instances": 1]
    }
    func recheck(_ frame: PacedFrame, hint: FollowHit, latestStart: Double) -> RFReply? {
        lock.lock()
        guard !priorityRequested else { lock.unlock(); return nil }
        priorityRequested = true; lock.unlock()
        defer { lock.lock(); priorityRequested = false; lock.unlock() }
        // One shared model. Wait behind at most the already-submitted regular job;
        // fresh regular submissions are blocked until this contact request finishes.
        return queue.sync {
            guard uptime() <= latestStart, thermal() < 3 else { return nil }
            return infer(frame, hint: hint, purpose: "contact")
        }
    }
    let model: MLModel
    let computeDescription: String
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: true])
    private let policy = RFAsyncPolicy()
    private let bridge: RFSegBridge
    let resolution: RFInputResolution
    init(resources: URL, resolution: RFInputResolution = RFDeviceProfile.current) throws {
        self.resolution = resolution
        let edge = resolution.rawValue
        bridge = RFSegBridge(edge: edge)
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndGPU
        configuration.functionName = resolution.functionName
        let url = resources.appendingPathComponent("RFDETRSmallRecovery040FP16.mlmodelc")
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
            computeDescription = "CPU + GPU"
        } catch {
            configuration.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: url, configuration: configuration)
            computeDescription = "CPU (compatibility)"
        }
        guard [288,384].contains(edge),
            model.modelDescription.inputDescriptionsByName["tensors"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,3,edge,edge] else {
            throw NSError(domain: "Diagnostic input shape mismatch", code: 1)
        }
    }
    var busy: Bool { lock.lock(); defer { lock.unlock() }; return occupied || priorityRequested }
    func infer(_ frame: PacedFrame, hint: FollowHit?, purpose: String = "regular") -> RFReply {
        lock.lock(); activeInferences += 1
        maximumActiveInferences = max(maximumActiveInferences, activeInferences)
        inferenceCounts[purpose, default: 0] += 1; lock.unlock()
        defer { lock.lock(); activeInferences -= 1; lock.unlock() }
        return autoreleasepool {
            let start = uptime()
            defer {
                lock.lock(); recentInferenceSeconds.append(uptime()-start)
                if recentInferenceSeconds.count > 8 { recentInferenceSeconds.removeFirst() }
                lock.unlock()
            }
            do {
                let prepared = try bridge.input(image: frame.image, context: context)
                let preparedAt = uptime(), output = try model.prediction(from: prepared)
                let predictedAt = uptime(), found = try candidates(output, size: frame.size)
                let (selected, reason) = policy.select(found, hint: hint)
                let decoded = try bridge.decode(output, sourceSize: frame.size, threshold: 0.4)
                return RFReply(frame: frame, found: decoded, selected: selected, reason: reason, candidateCount: found.count, candidates: found, started: start,
                    preparationMS: (preparedAt-start)*1000, predictionMS: (predictedAt-preparedAt)*1000,
                    completed: uptime(), error: nil)
            } catch {
                return RFReply(frame: frame, found: FrameDetections(ball: nil, person: nil), selected: nil, reason: "error", candidateCount: 0, candidates: [], started: start,
                    preparationMS: 0, predictionMS: 0, completed: uptime(), error: String(describing: error))
            }
        }
    }
    func submit(_ frame: PacedFrame, hint: FollowHit?) -> Bool {
        lock.lock()
        guard !occupied && !priorityRequested else { lock.unlock(); return false }
        occupied = true; lock.unlock()
        queue.async {
            let value = self.infer(frame, hint: hint)
            self.lock.lock(); self.reply = value; self.lock.unlock()
        }
        return true
    }
    func take() -> RFReply? {
        lock.lock(); defer { lock.unlock() }
        guard let reply else { return nil }
        self.reply = nil; occupied = false; return reply
    }
    func drain() -> RFReply? { queue.sync {}; return take() }
}

// Counting may consume a bounded, delayed sequence in original timestamp order.
// This is separate from a current-camera overlay: each observation retains the
// frame it actually describes. No box is interpolated through a missing track.
nonisolated final class BufferedTracking {
    let worker: RFWorker
    let delay: Double
    let cadence: RFCadencePolicy
    private var submissionRecords: [Int: [String: Any]] = [:]
    let initialBackground: StationaryCandidateGate?
    let policy = RFAsyncPolicy()
    let counter: RFLiveConsumer
    private var people: ([Detection], Double)?
    private let tracker = RFBufferedPixelTrack()
    private var pending: [PacedFrame] = []
    private var replies: [Int: RFReply] = [:]
    private var lastSubmitted = -Double.infinity
    private var consumedIndex = -1
    private var seedTime: Double?
    private var previous: (FollowHit, Double)?
    private var motionRecovery = RFMotionRecovery()
    private var statuses: [Int: String] = [:]
    var rows: [[String: Any]] = []
    var events: [[String: Any]] = []
    var maximumPending = 0
    var maximumReplies = 0
    var submissions = 0
    var lateReplies = 0
    var overflowDrops = 0
    init(worker: RFWorker, delay: Double, cadence: RFCadencePolicy, stationaryGate: Bool = false, softConfidence: Bool = false, counter: RFLiveConsumer) {
        self.counter = counter
        self.worker = worker; self.delay = delay; self.cadence = cadence
        self.initialBackground = stationaryGate ? StationaryCandidateGate() : nil
        self.tracker.softConfidenceEnabled = softConfidence
    }
    nonisolated private func receive() throws {
        guard let result = worker.take() else { return }
        if let error = result.error { throw NSError(domain: error, code: 1) }
        events.append(["source_frame": result.frame.index, "source_seconds": result.frame.time,
            "prediction_ms": result.predictionMS, "preparation_ms": result.preparationMS,
            "inference_start_uptime": result.started, "completion_latency_ms": (result.completed-result.frame.due)*1000,
            "candidate_count": result.candidateCount, "mask_decoded": result.found.ballMask != nil])
        if result.frame.index <= consumedIndex {
            lateReplies += 1; statuses[result.frame.index] = "late_result_discarded"
        } else { replies[result.frame.index] = result }
        maximumReplies = max(maximumReplies, replies.count)
    }
    nonisolated private func processDue() throws {
        try receive()
        while let first = pending.first, uptime() >= first.due+delay {
            pending.removeFirst()
            try autoreleasepool {
                let begin = uptime()
                var failureDetails: [String: Any] = [:]
                var hit: FollowHit?, kind = "missing", association = "no_rf_this_frame"
                var mask: BallMask?
                var metrics = RFFrameMetrics(compute: worker.computeDescription)
                if let seedTime, first.time-seedTime <= policy.maximumTrackAge+0.000001 {
                    tracker.detectorAgeSeconds = first.time-seedTime
                    hit = tracker.update(first.image, size: first.size)
                    failureDetails["soft_confidence_used"] = tracker.diagnosticSoftConfidenceUsed
                    if let reason = tracker.diagnosticFailure { failureDetails["tracker_failure"] = reason }
                    if let value = tracker.diagnosticConfidence, value.isFinite { failureDetails["vision_confidence"] = value }
                    if let value = tracker.diagnosticScale, value.isFinite { failureDetails["scale_ratio"] = value }
                    if let value = tracker.diagnosticCorrelation, value.isFinite { failureDetails["texture_correlation"] = value }
                    if let box = tracker.diagnosticRect {
                        failureDetails["vision_candidate_xywh"] = [box.minX/first.size.width, box.minY/first.size.height, box.width/first.size.width, box.height/first.size.height]
                    }
                    if hit != nil { kind = "pixel_tracking" }
                } else { tracker.reset(); seedTime = nil }
                if let reply = replies.removeValue(forKey: first.index) {
                    people = (reply.found.people.isEmpty ? reply.found.person.map { [$0] } ?? [] : reply.found.people, first.time)
                    metrics.lastInferenceMS = reply.predictionMS
                    metrics.lastPreprocessMS = reply.preparationMS
                    metrics.lastTotalMS = reply.predictionMS + reply.preparationMS
                    let hint = hit ?? previous.flatMap { first.time-$0.1 <= policy.maximumHintAge ? $0.0 : nil }
                    let eligible = initialBackground?.eligible(reply.candidates) ?? reply.candidates
                    var (selection, reason) = policy.select(eligible, hint: hint)
                    if selection == nil, hit == nil, reason == "identity_gate_rejected",
                       RFMotionRecovery.enabled(),
                       let recovered = motionRecovery.select(eligible, at: first.time) {
                        selection = recovered
                        reason = "motion_reacquired"
                    }
                    association = eligible.isEmpty && !reply.candidates.isEmpty ? "stationary_initial_candidates_rejected" : reason
                    if let selection {
                        hit = selection.hit; kind = "rf_detection"
                        // The decoder's mask belongs only to its selected query on this exact exposure.
                        if let b = reply.found.ball {
                            let chosen = detection(selection.hit, size: first.size)
                            if abs(b.x-chosen.x) < 0.00001 && abs(b.y-chosen.y) < 0.00001 && abs(b.width-chosen.width) < 0.00001 && abs(b.height-chosen.height) < 0.00001 {
                                mask = reply.found.ballMask
                            }
                        }
                        tracker.seed(selection.hit, image: first.image, size: first.size); seedTime = first.time
                        statuses[first.index] = "used_direct_at_original_frame"
                    } else { statuses[first.index] = "no_detection_preserved_track" }
                }
                if let hit {
                    previous = (hit, first.time)
                    motionRecovery.observe(hit, at: first.time)
                }
                let currentPeople = people.flatMap { first.time-$0.1 <= 0.4 ? $0.0 : nil } ?? []
                metrics.lastFollowKind = kind == "rf_detection" ? "detector" : "pixel_track"
                metrics.lastFollowCalls = kind == "rf_detection" ? 1 : 0
                let found = FrameDetections(ball: hit.map { detection($0, size: first.size) }, person: currentPeople.first,
                    people: currentPeople, ballMask: mask, usesBallMasks: true)
                let counterRow = try counter.submit(RFTrackedFrame(frame: first, found: found, metrics: metrics))
                var row: [String: Any] = ["frame": first.index, "source_seconds": first.time,
                    "available": hit != nil, "kind": kind, "association": association,
                    "processing_ms": (uptime()-begin)*1000, "latency_ms": (uptime()-first.due)*1000,
                    "memory_mib": memoryMB(), "thermal": thermal(), "buffered_frames": pending.count]
                if let hit {
                    row["box_xywh_normalized"] = [hit.rect.minX/first.size.width, hit.rect.minY/first.size.height,
                                                  hit.rect.width/first.size.width, hit.rect.height/first.size.height]
                    row["seed_detector_score"] = hit.score
                    row["detector_age_ms"] = (first.time-seedTime!)*1000
                }
                row.merge(counterRow) { _, new in new }
                row.merge(failureDetails) { _, new in new }
                rows.append(row); if rows.count > 6000 { rows.removeFirst(rows.count-6000) }; consumedIndex = first.index
            }
            try receive()
        }
    }
    func accept(_ frame: PacedFrame) throws {
        try processDue()
        let state = thermal(), now = uptime()
        let targetHz = cadence.targetHz(thermalState: state)
        if targetHz > 0, now-lastSubmitted >= 1/targetHz, !worker.busy {
            // Only scheduling changes. The one-job bound and source identity remain.
            if worker.submit(frame, hint: nil) {
                var record: [String: Any] = ["submission_uptime": now,
                    "target_hz": targetHz, "submission_thermal": state]
                if lastSubmitted.isFinite { record["previous_submission_uptime"] = lastSubmitted }
                submissionRecords[frame.index] = record
                lastSubmitted = now; submissions += 1
            }
        }
        pending.append(frame)
        if pending.count > 16 {
            let old = pending.removeFirst(); replies.removeValue(forKey: old.index)
            statuses[old.index] = "buffer_overflow"; consumedIndex = old.index; overflowDrops += 1
            rows.append(["frame": old.index, "source_seconds": old.time, "available": false,
                "kind": "buffer_overflow", "latency_ms": (uptime()-old.due)*1000, "thermal": thermal()])
        }
        maximumPending = max(maximumPending, pending.count)
    }
    func skip(index: Int, time: Double, due: Double) throws {
        try processDue()
        rows.append(["frame": index, "source_seconds": time, "kind": "sampling_skip", "available": false,
                     "latency_ms": (uptime()-due)*1000, "thermal": thermal()])
    }
    func drop(index: Int, time: Double, due: Double) throws {
        try processDue()
        rows.append(["frame": index, "source_seconds": time, "kind": "dropped_late", "available": false,
                     "latency_ms": (uptime()-due)*1000, "thermal": thermal()])
    }
    func finish() throws -> [String: Any] {
        while let first = pending.first {
            let wait = first.due+delay-uptime()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            try processDue()
        }
        // Drain after all scheduled analysis deadlines; late final results are
        // recorded and discarded, never used to revise an already published row.
        if let final = worker.drain() {
            if let error = final.error { throw NSError(domain: error, code: 1) }
            lateReplies += 1
            events.append(["source_frame": final.frame.index, "source_seconds": final.frame.time,
                "prediction_ms": final.predictionMS, "preparation_ms": final.preparationMS,
                "inference_start_uptime": final.started, "completion_latency_ms": (final.completed-final.frame.due)*1000,
                "candidate_count": final.candidateCount])
            statuses[final.frame.index] = "late_result_discarded"
        }
        for i in events.indices {
            let frame = events[i]["source_frame"] as! Int
            events[i]["use"] = statuses[frame] ?? "discarded_unavailable_frame"
            guard let record = submissionRecords[frame] else {
                throw NSError(domain: "Missing cadence submission record", code: 1)
            }
            events[i].merge(record) { _, new in new }
        }
        tracker.reset(); previous = nil; replies.removeAll()
        return ["samples": rows.sorted { ($0["frame"] as! Int) < ($1["frame"] as! Int) },
            "rf_events": events, "rf_submissions": submissions, "late_replies": lateReplies,
            "maximum_buffered_frames": maximumPending, "buffer_capacity_frames": 16,
            "maximum_buffered_replies": maximumReplies, "overflow_drops": overflowDrops,
            "analysis_delay_ms": delay*1000, "cadence_mode": cadence.mode.rawValue,
            "inference_queue_capacity": 1]
    }
}


nonisolated private func detection(_ hit: FollowHit, size: CGSize) -> Detection {
    Detection(score: hit.score, x: hit.rect.midX/size.width, y: hit.rect.midY/size.height,
              width: hit.rect.width/size.width, height: hit.rect.height/size.height)
}


// Owning queue: the serial contact worker. All original verifier rules stay in
// JugglingContactVerifier. This wrapper prepares evidence before its first gate.
nonisolated final class ContactRecheckEvidence: ContactEvidenceProviding {
    private struct Missing {
        let frame: PacedFrame
        let hint: FollowHit
        let hintTime: Double
        let hintIndex: Int
    }
    private struct Observed {
        let hit: FollowHit
        let time: Double
        let index: Int
    }
    let verifier: JugglingContactVerifier
    private let observations: ContactObservationStore
    private let worker: RFWorker
    private let enabled: Bool
    let backlogGuard: Bool
    var queueSnapshot: () -> (Int, Double) = { (-1, .infinity) }
    private let backlogPolicy = ContactBacklogPolicy()
    private let policy = ContactRecheckPolicy()
    private var missing: [Int: Missing] = [:]
    private var observed: [Observed] = []
    private var attempted: Set<Int> = []
    private var pending: Int?
    private var latestSource = 0.0
    private var operation = 0
    private var lastSource = -Double.infinity
    private var lastWall = -Double.infinity
    private(set) var events: [[String: Any]] = []
    private(set) var peakRetainedMissingFrames = 0
    private(set) var error: String?

    init(observations: ContactObservationStore, verifier: JugglingContactVerifier,
         worker: RFWorker, enabled: Bool, backlogGuard: Bool) {
        self.observations = observations; self.verifier = verifier
        self.worker = worker; self.enabled = enabled; self.backlogGuard = backlogGuard
    }
    func arrive(_ frame: PacedFrame, index: Int, ball: Detection?, reliable: Bool) {
        latestSource = frame.time; operation = index
        guard enabled else { return }
        guard reliable else {
            missing.removeAll(); observed.removeAll(); attempted.removeAll(); pending = nil
            return
        }
        observed.removeAll { frame.time-$0.time > 0.6 }
        if let ball {
            let box = CGRect(x: (ball.x-ball.width/2)*frame.size.width,
                y: (ball.y-ball.height/2)*frame.size.height,
                width: ball.width*frame.size.width, height: ball.height*frame.size.height)
            observed.append(Observed(hit: FollowHit(rect: box, score: ball.score), time: frame.time, index: index))
        } else if let before = observed.last,
                  frame.time-before.time <= policy.maximumHintAge+0.000001 {
            missing[index] = Missing(frame: frame, hint: before.hit, hintTime: before.time, hintIndex: before.index)
        }
        missing = missing.filter { frame.time-$0.value.frame.time <= policy.maximumRetainedAge+0.000001 }
        while missing.count > policy.maximumRetainedFrames {
            guard let oldest = missing.keys.filter({ $0 != pending }).min() else { break }
            missing.removeValue(forKey: oldest)
        }
        attempted = Set(attempted.filter { $0 >= index-120 || $0 == pending })
        peakRetainedMissingFrames = max(peakRetainedMissingFrames, missing.count)
    }
    func reset() {
        missing.removeAll(); observed.removeAll(); attempted.removeAll(); pending = nil
        latestSource = 0; operation = 0; lastSource = -.infinity; lastWall = -.infinity
        events.removeAll(); error = nil; peakRetainedMissingFrames = 0
    }
    func beginFlush(operation: Int) { self.operation = operation }

    private func prepare(_ index: Int, trigger: String) {
        guard enabled, error == nil,
              !observations.frames.contains(where: { $0.index == index }),
              attempted.insert(index).inserted else { return }
        var event: [String: Any] = ["analysis_frame": index, "trigger": trigger,
            "operation": operation, "arrived_source_seconds": latestSource,
            "request_uptime": uptime(), "attempted": false, "applied": false]
        defer { events.append(event) }
        guard let retained = missing.removeValue(forKey: index) else {
            event["reason"] = "no_retained_eligible_frame"; return
        }
        let frame = retained.frame, now = uptime()
        event.merge(["source_frame": frame.index, "source_seconds": frame.time,
            "source_due_uptime": frame.due, "request_uptime": now,
            "request_latency_ms": (now-frame.due)*1000,
            "before_hint_seconds": retained.hintTime, "before_hint_analysis_frame": retained.hintIndex,
            "retained_input_width": frame.size.width, "retained_input_height": frame.size.height]) { _, new in new }
        guard let after = observed.first(where: { $0.time > frame.time }) else {
            event["reason"] = "no_arrived_release_identity"; return
        }
        event["after_hint_seconds"] = after.time
        event["after_hint_analysis_frame"] = after.index
        guard policy.permits(source: frame.time, before: retained.hintTime, after: after.time,
                arrived: latestSource, now: now, due: frame.due, lastSource: lastSource, lastWall: lastWall) else {
            event["reason"] = "age_or_rate_limit"; return
        }
        let budget = worker.recheckBudget
        func admit(_ stage: String) -> Bool {
            let (depth, lag) = queueSnapshot()
            event[stage+"_queue_depth"] = depth
            event[stage+"_current_frame_lag_ms"] = lag*1000
            event[stage+"_rf_budget_ms"] = budget*1000
            if lag.isFinite, budget.isFinite {
                event[stage+"_projected_frames"] = backlogPolicy.projectedFrames(outstanding: depth, rfBudget: budget)
            }
            return backlogPolicy.permits(outstanding: depth, currentFrameLag: lag, rfBudget: budget)
        }
        event["backlog_guard_enabled"] = backlogGuard
        let admission = admit("request")
        if backlogGuard && !admission { event["reason"] = "backlog_limit"; return }
        lastSource = frame.time; lastWall = now
        event["attempted"] = true
        let result: (RFReply?, String)
        if backlogGuard {
            result = worker.recheckIfIdle(frame, hint: retained.hint,
                latestStart: frame.due+policy.maximumStartLatency, admit: { admit("start") })
        } else {
            result = (worker.recheck(frame, hint: retained.hint,
                latestStart: frame.due+policy.maximumStartLatency), "legacy_waiting_worker")
        }
        event["worker_admission"] = result.1
        guard let reply = result.0 else { event["reason"] = result.1; return }
        event["inferred"] = true
        event["prediction_ms"] = reply.predictionMS
        event["preparation_ms"] = reply.preparationMS
        event["inference_start_uptime"] = reply.started
        event["completion_uptime"] = reply.completed
        event["completion_latency_ms"] = (reply.completed-frame.due)*1000
        event["candidate_count"] = reply.candidateCount
        if let failure = reply.error { error = failure; event["reason"] = "inference_error"; return }
        guard policy.acceptsResult(now: reply.completed, due: frame.due) else {
            event["reason"] = "late_result_discarded"; return
        }
        guard let selected = reply.selected else { event["reason"] = reply.reason; return }
        guard RFAsyncPolicy().select([selected], hint: after.hit).0 != nil else {
            event["reason"] = "release_identity_gate_rejected"; return
        }
        let ball = detection(selected.hit, size: frame.size)
        event["score"] = ball.score
        event["selected_query"] = selected.query
        event["box_xywh_normalized"] = [ball.x-ball.width/2, ball.y-ball.height/2, ball.width, ball.height]
        let applied = observations.insertRecheckedContact(frame.pixels, frameIndex: index,
            timestampMs: frame.timestampMs, ball: ball)
        event["applied"] = applied
        event["reason"] = applied ? "measured_contact_evidence_inserted" : "observation_store_rejected"
    }
    func retainContactFrames(around index: Int?) {
        pending = index; verifier.retainContactFrames(around: index)
    }
    func rejectsHandContact(at frameIndex: Int) -> Bool {
        prepare(frameIndex, trigger: "hand"); return verifier.rejectsHandContact(at: frameIndex)
    }
    func allowsBodyContact(at frameIndex: Int, policy: CountingPolicy.BodyContact) -> Bool {
        prepare(frameIndex, trigger: "body"); return verifier.allowsBodyContact(at: frameIndex, policy: policy)
    }

    func footEvidence(at frameIndex: Int) -> FootContactEvidence? {
        prepare(frameIndex, trigger: "foot"); return verifier.footEvidence(at: frameIndex)
    }
    func groundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence? {
        prepare(frameIndex, trigger: "ground"); return verifier.groundEvidence(at: frameIndex, timed: timed)
    }
    func handlingEvidence(at frameIndex: Int) -> BallHandlingEvidence? {
        prepare(frameIndex, trigger: "handling"); return verifier.handlingEvidence(at: frameIndex)
    }
    func diagnostic(for decision: CounterDecision, ball: BallObservation?) -> TouchDebugEvent {
        // Diagnostics must never start inference after a decision was made.
        verifier.diagnostic(for: decision, ball: ball)
    }
}


nonisolated struct AsyncBallCandidate {
    let query: Int
    let hit: FollowHit
}
nonisolated struct RFAsyncPolicy {
    let minimumRFInterval: Double = 0.2
    let maximumResultAge: Double = 0.3
    let maximumTrackAge: Double = 0.4
    let maximumHintAge: Double = 0.25
    let historySeconds: Double = 0.4
    let historyFrames: Int = 13
    let maximumCatchupFrames: Int = 10

    func maySubmit(now: Double, last: Double, busy: Bool) -> Bool {
        !busy && now - last >= minimumRFInterval - 0.000001
    }
    func mayCatchUp(source: Double, current: Double, frames: Int, containsSeed: Bool) -> Bool {
        containsSeed && current >= source && current-source <= maximumResultAge + 0.000001
            && frames >= 0 && frames <= maximumCatchupFrames
    }
    func select(_ candidates: [AsyncBallCandidate], hint: FollowHit?) -> (AsyncBallCandidate?, String) {
        guard let highest = candidates.max(by: { $0.hit.score < $1.hit.score }) else { return (nil, "rf_empty") }
        guard let hint else { return (highest, "highest_score_without_recent_identity") }
        let ranked = candidates.map { c -> (AsyncBallCandidate, Double) in
            let d = hypot(c.hit.center.x-hint.center.x, c.hit.center.y-hint.center.y)
                / max(1, hint.diameter)
            return (c, d)
        }.filter { $0.1 <= 3 && (0.5...2).contains($0.0.hit.diameter / max(1, hint.diameter)) }
        guard let best = ranked.min(by: { $0.1 == $1.1 ? $0.0.hit.score > $1.0.hit.score : $0.1 < $1.1 }) else {
            return (nil, "identity_gate_rejected")
        }
        return (best.0, best.0.query == highest.query ? "associated_highest" : "associated_other_query")
    }
}

// Fixed-camera diagnostic only. First-frame objects become background anchors;
// candidates must newly appear or move away before they can seed a ball track.
// A moving camera or a ball crossing an anchor can invalidate this heuristic.
nonisolated final class StationaryCandidateGate {
    private var initial: [AsyncBallCandidate]?
    func eligible(_ candidates: [AsyncBallCandidate]) -> [AsyncBallCandidate] {
        guard let initial else { self.initial = candidates; return [] }
        return candidates.filter { candidate in
            !initial.contains { anchor in
                let distance = hypot(candidate.hit.center.x-anchor.hit.center.x,
                                     candidate.hit.center.y-anchor.hit.center.y)
                let scale = candidate.hit.diameter / max(1, anchor.hit.diameter)
                return distance <= 0.5 * anchor.hit.diameter && (0.5...2).contains(scale)
            }
        }
    }
}

nonisolated enum GuardedTrackingConfidence {
    static func allows(_ confidence: Float, correlation: Float, detectorAge: Double, enabled: Bool) -> Bool {
        guard confidence.isFinite, correlation.isFinite, detectorAge.isFinite, detectorAge >= 0 else { return false }
        if confidence >= 0.5 { return correlation >= 0.45 }
        return enabled && confidence >= 0.4 && correlation >= 0.65 && detectorAge <= 0.15
    }
}


nonisolated private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
nonisolated private func thermal() -> Int { ProcessInfo.processInfo.thermalState.rawValue }
nonisolated private func memoryMB() -> Double { DetectorPerformance.memoryMB() }
nonisolated private func number(_ a: MLMultiArray, _ i: Int) -> Double { RFSegBridge.value(a, i) }


// Full-app integration boundary. Analysis owns tracking; a single serial
// consumer owns player selection, pose evidence, counting and saved results.
nonisolated struct RFFrameMetrics {
    let compute: String
    var lastInferenceMS = 0.0, lastPreprocessMS = 0.0, lastTotalMS = 0.0
    var lastFollowKind = "pixel_track", lastFollowCalls = 0
    var wantsModelInputSnapshot = false
    var modelName: String { "RF-DETR Small · \(RFDeviceProfile.current.rawValue) · buffered live" }
    var modelComputeDescription: String { compute }
    var plausibilityPolicy: BallPlausibility.Policy { .rfDetrAssociationV1 }
    var hasMaskOutputs: Bool { true }
    var fullFrameCount: Int { 0 }
    var cropFrameCount: Int { 0 }
    var lastInputSize: CGSize { CGSize(width: RFDeviceProfile.current.rawValue, height: RFDeviceProfile.current.rawValue) }
    var lastModelInput: CGImage? { nil }
    var lastError: String? { nil }
}
nonisolated struct RFTrackedFrame {
    let frame: PacedFrame
    let found: FrameDetections
    let metrics: RFFrameMetrics
    var liveFrame: LiveAnalysisFrame {
        LiveAnalysisFrame(pixels: frame.pixels, sourceTime: frame.time, startTime: frame.recordingStart,
                          captureDrops: frame.captureDrops, identity: frame.identity, sourceDueUptime: frame.due)
    }
}
nonisolated final class RFLiveConsumer {
    let preview = LiveEffectFrames()
    let queue = DispatchQueue(label: "rf.fullapp.contact", qos: .userInitiated)
    let lock = NSLock()
    var process: ((RFTrackedFrame) throws -> LiveAnalysisUpdate?)?
    private var outstanding = 0, peak = 0, processed = 0
    private var latest: LiveAnalysisUpdate?
    private var failure: Error?
    var summary: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["processed": processed, "maximum_queue_depth": peak, "queue_capacity": 32, "outstanding": outstanding]
    }
    func reset() {
        queue.sync {}
        preview.reset()
        lock.lock(); defer { lock.unlock() }
        outstanding = 0; peak = 0; processed = 0; latest = nil; failure = nil
    }
    func submit(_ output: RFTrackedFrame) throws -> [String: Any] {
        lock.lock()
        if let failure { lock.unlock(); throw failure }
        guard outstanding < 32 else {
            lock.unlock()
            throw NSError(domain: "RFContactQueue", code: 1, userInfo: [NSLocalizedDescriptionKey: "The phone could not keep up with counting. The video has been saved."])
        }
        outstanding += 1; peak = max(peak, outstanding); let depth = outstanding
        lock.unlock()
        preview.publish(pixels: output.frame.pixels, time: output.frame.time - output.frame.recordingStart,
                        due: output.frame.due, ball: output.found.ball)
        queue.async {
            do {
                let update = try autoreleasepool { try self.process?(output) }
                self.lock.lock()
                if let update { self.latest = update }
                self.processed += 1
                self.lock.unlock()
            } catch { self.lock.lock(); self.failure = error; self.lock.unlock() }
            self.lock.lock(); self.outstanding -= 1; self.lock.unlock()
        }
        return ["counter_enqueued": true, "counter_queue_depth": depth]
    }
    func takeUpdate() throws -> LiveAnalysisUpdate? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        let result = latest; latest = nil; return result
    }
    func drain() throws {
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
    }
}

nonisolated final class LiveJugglingAnalysis {
    typealias Result = RFAppCounterCore.Result
    private let core: RFAppCounterCore
    private var consumer = RFLiveConsumer()
    var preview: LiveEffectFrames { consumer.preview }
    private var worker: RFWorker?
    private var engine: BufferedTracking?
    private var accepted = 0
    private var reportID = UUID()
    private var context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var lastSource: Double?
    private var lastReport: [String: Any] = [:]
    private var motionEnabled = true
    private var runStartUptime = 0.0
    private var failures = [String]()
    var recommendedFramesPerSecond: Double { 30 }
    var isPrepared: Bool { worker != nil && consumer.queue.sync { core.isPrepared } }
    #if DEBUG
    var finalTestFiles: FinalTestFiles?
    #endif
    init(counterConfig: CounterConfig = CounterConfig()) { core = RFAppCounterCore(counterConfig: counterConfig) }

    func prepare(request: CaptureRequest) throws -> Bool {
        release()
        guard !request.isCancelled else { return false }
        let worker = try RFWorker(resources: Bundle.main.resourceURL!)
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 288, 512, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, let pixels else {
            throw NSError(domain: "RFWarmup", code: 1)
        }
        context.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 288, height: 512)), to: pixels)
        let frame = PacedFrame(index: 0, time: 0, due: uptime(), image: CIImage(cvPixelBuffer: pixels), pixels: pixels)
        for _ in 0..<2 {
            guard !request.isCancelled else { return false }
            let reply = worker.infer(frame, hint: nil, purpose: "warmup")
            if let error = reply.error { throw NSError(domain: "RFWarmup", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
        }
        let prepared = try consumer.queue.sync { try core.prepare(request: request, worker: worker) }
        guard prepared, !request.isCancelled else { consumer.queue.sync { core.release() }; return false }
        self.worker = worker
        consumer.process = { [weak self] output in
            guard let self else { return nil }
            return try self.core.process(output, motionCompensationEnabled: self.motionEnabled)
        }
        return true
    }
    func release() {
        engine = nil
        _ = worker?.drain()
        try? consumer.drain()
        consumer.preview.reset()
        consumer.queue.sync { core.release() }
        worker = nil; pool = nil; context.clearCaches()
    }
    func resetCounter() {
        try? consumer.drain()
        consumer.queue.sync { core.resetCounter() }
        consumer.reset()
    }
    func beginRecording() {
        guard let worker else { return }
        consumer.reset(); accepted = 0; lastSource = nil; reportID = UUID(); failures = []; lastReport = [:]
        runStartUptime = uptime()
        consumer.queue.sync {
            #if DEBUG
            core.finalTestFiles = finalTestFiles
            #endif
            core.beginRecording()
        }
        engine = BufferedTracking(worker: worker, delay: 0.2, cadence: RFCadencePolicy(mode: .fixed12),
                                  stationaryGate: true, softConfidence: true, counter: consumer)
    }
    private func ownedPortrait(_ pixels: CVPixelBuffer) throws -> CVPixelBuffer {
        var image = CIImage(cvPixelBuffer: pixels)
        if image.extent.width > image.extent.height { image = image.oriented(.right) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, 1280/image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
        let size = CGSize(width: width, height: height)
        if pool == nil || poolSize != size {
            let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else {
                throw NSError(domain: "RFPixelPool", code: 1)
            }
            poolSize = size
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool!,
            [kCVPixelBufferPoolAllocationThresholdKey: 48] as CFDictionary, &output) == kCVReturnSuccess, let output else {
            throw NSError(domain: "RFPixelPool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Counting reached its image-buffer limit. The video has been saved."])
        }
        context.render(image, to: output)
        return output
    }
    func process(_ frame: LiveAnalysisFrame, request: CaptureRequest,
                 motionCompensationEnabled: Bool) throws -> LiveAnalysisUpdate? {
        guard !request.isCancelled, let engine else { return nil }
        // Captured when this take starts and identical for every submitted job.
        if accepted == 0 { motionEnabled = motionCompensationEnabled }
        do {
            guard thermal() < 3 else {
                throw NSError(domain: "RFThermal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording stopped so the phone can cool. Your video has been saved."])
            }
            guard frame.sourceTime.isFinite, frame.sourceDueUptime.isFinite else { throw NSError(domain: "RFFrameOrder", code: 1) }
            // A repeated or out-of-order frame is dropped like a throttled one; it must never end the take.
            if let lastSource, frame.sourceTime <= lastSource { return nil }
            let pixels = try ownedPortrait(frame.pixels)
            let paced = PacedFrame(index: accepted, time: frame.sourceTime, due: frame.sourceDueUptime,
                image: CIImage(cvPixelBuffer: pixels), pixels: pixels, identity: frame.identity,
                recordingStart: frame.startTime, captureDrops: frame.captureDrops)
            accepted += 1; lastSource = frame.sourceTime
            try engine.accept(paced)
            return try consumer.takeUpdate()
        } catch {
            failures.append(error.localizedDescription)
            consumer.queue.sync { core.markFailed() }
            throw error
        }
    }
    func finish(flush: Bool, wasActive: Bool) -> Result {
        if let engine, wasActive {
            do { lastReport = try engine.finish(); try consumer.drain() }
            catch { failures.append(error.localizedDescription); consumer.queue.sync { core.markFailed() } }
        }
        try? consumer.drain()
        let result = consumer.queue.sync { core.finish(flush: flush, wasActive: wasActive) }
        let checks = consumer.queue.sync { core.recheckEvents }
        let latencies = consumer.queue.sync { core.notificationLatencies }
        if wasActive {
            lastReport["accepted_frames"] = accepted
            lastReport["counter"] = consumer.summary
            lastReport["count"] = result.count
            lastReport["quality_failed"] = result.qualityFailed
            lastReport["errors"] = failures
            lastReport["elapsed_wall_seconds"] = uptime()-runStartUptime
            lastReport["notification_latency_ms"] = latencies
            lastReport["rechecks"] = checks
            lastReport["worker"] = worker?.statistics
            lastReport["backend"] = worker?.computeDescription
            lastReport["model"] = RFSmallModel.fp16.displayName
            lastReport["hardware_model"] = RFDeviceProfile.hardwareIdentifier
            lastReport["resolution"] = RFDeviceProfile.current.rawValue
            lastReport["function"] = RFDeviceProfile.current.functionName
            lastReport["profile_policy"] = RFDeviceProfile.policyVersion
            lastReport["active_player_selection"] = true
            lastReport["frame_count"] = result.frameCount
            lastReport["track_count"] = result.track.count
            lastReport["exact_frame_masks"] = result.track.filter { $0.ballMask != nil }.count
            lastReport["pipeline"] = SessionAnalysisStore.pipelineSignature()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--rf-full-app-check") {
            let folder = URL.documentsDirectory.appendingPathComponent("RFFullApp/"+reportID.uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try RFDiagnosticJSON.data(lastReport).write(to: folder.appendingPathComponent("report.json"))
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                if let trace = result.trace { try encoder.encode(trace).write(to: folder.appendingPathComponent("counter.plist")) }
                try SessionAnalysisStore.frameData(result.track).write(to: folder.appendingPathComponent("track.plist"))
                try JSONSerialization.data(withJSONObject: result.touches.map { [Double($0.index), $0.time, $0.x, $0.y] }).write(to: folder.appendingPathComponent("touches.json"))
                try folder.lastPathComponent.write(to: URL.documentsDirectory.appendingPathComponent("RFFullApp/latest.txt"), atomically: true, encoding: .utf8)
            } catch { NSLog("RF full-app report: %@", error.localizedDescription) }
            }
            #endif
        }
        release()
        return result
    }
}
