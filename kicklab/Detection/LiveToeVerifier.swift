import CoreVideo
import Foundation
import MediaPipeTasksVision

/// Owned by one sequential live consumer or import run. Native vetoes run first.
nonisolated final class LiveToeVerifier: ContactEvidenceProviding {
    private let base: any ContactEvidenceProviding
    private let observations: ContactObservationStore
    private var landmarker: PoseLandmarker?
    private let modelPath: String
    private let persistentKind: String?
    private struct Landmark: Codable {
        let x, y, z: Double
        let visibility, presence: Double?
        init(_ point: NormalizedLandmark) {
            x = Double(point.x); y = Double(point.y); z = Double(point.z)
            visibility = point.visibility?.doubleValue; presence = point.presence?.doubleValue
        }
    }
    private var cache: [Int: FootContactRules.Sample] = [:]
    private var attempted: Set<Int> = []
    private let singlePersonControl = CounterV2Policy.singlePersonControl
    private let extendedContacts = CounterV2Policy.extendedContacts
    private let auditsEnabled = ProcessInfo.processInfo.arguments.contains("--counter-toe-audit")
    private var poseAudit: [Int: [String: Any]] = [:]
    private(set) var auditRows: [[String: Any]] = []
    private(set) var error: String?
    private(set) var requests = 0
    private(set) var recoveries = 0
    private(set) var cacheHits = 0
    private(set) var inferenceSeconds = 0.0
    private(set) var warmUpSeconds = 0.0
    static func failure(_ message: String) -> NSError {
        NSError(domain: "CounterLive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    init(base: any ContactEvidenceProviding, observations: ContactObservationStore) throws {
        let start = ProcessInfo.processInfo.systemUptime
        self.base = base; self.observations = observations
        guard let path = Bundle.main.path(forResource: CounterV2Policy.poseModelName, ofType: "task") else {
            throw Self.failure("Missing toe model")
        }
        modelPath = path
        if observations.predictionStore != nil {
            guard let runtime = Bundle.main.object(forInfoDictionaryKey:"PoseReuseRuntimeSHA256") as? String, runtime.count == 64 else {
                throw Self.failure("Missing pose runtime identity")
            }
            persistentKind = "toe|model=" + (try PosePredictionStore.fileDigest(URL(fileURLWithPath:path)))
                + "|runtime=" + runtime + "|cpu|image|up|poses=\(singlePersonControl ? 1 : 2)|detect=0.5|presence=0.5|track=0.5|masks=false|decode-v1"
        } else { persistentKind = nil }
        guard observations.predictionStore == nil else { return }
        let landmarker = try model()
        // Complete initial graph setup before enabling Start.
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 288, 512, kCVPixelFormatType_32BGRA,
              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Self.failure("Toe model warm-up buffer failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(buffer) {
            memset(bytes, 0, CVPixelBufferGetBytesPerRow(buffer)*CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        _ = try landmarker.detect(image: MPImage(pixelBuffer: buffer, orientation: .up))
        warmUpSeconds = ProcessInfo.processInfo.systemUptime-start
    }
    /// The durable import path need not construct the graph when every input is saved.
    private func model() throws -> PoseLandmarker {
        if let landmarker { return landmarker }
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.baseOptions.delegate = .CPU
        options.runningMode = .image
        options.numPoses = singlePersonControl ? 1 : 2
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.shouldOutputSegmentationMasks = false
        let created = try PoseLandmarker(options: options)
        landmarker = created
        return created
    }
    func reset() {
        cache.removeAll(); attempted.removeAll(); poseAudit.removeAll(); auditRows.removeAll(); error = nil
        requests = 0; recoveries = 0; cacheHits = 0; inferenceSeconds = 0
    }
    func configure(policy: CountingPolicy) { base.configure(policy: policy) }
    func rejectsHandContact(at i: Int) -> Bool { base.rejectsHandContact(at: i) }
    func allowsBodyContact(at i: Int, policy: CountingPolicy.BodyContact) -> Bool { base.allowsBodyContact(at: i, policy: policy) }
    func groundEvidence(at i: Int, timed: Bool) -> GroundContactEvidence? {
        recoverGround(base.groundEvidence(at: i, timed: timed), at: i)
    }
    func handlingEvidence(at i: Int) -> BallHandlingEvidence? { base.handlingEvidence(at: i) }
    func streakHandlingEvidence(now: Int, after lastTouchMs: Int) -> BallHandlingEvidence? { base.streakHandlingEvidence(now: now, after: lastTouchMs) }
    func streakGroundEvidence(at i: Int, timed: Bool) -> GroundContactEvidence? {
        recoverGround(base.streakGroundEvidence(at: i, timed: timed), at: i)
    }
    func retainContactFrames(around i: Int?) { base.retainContactFrames(around: i) }
    func diagnostic(for d: CounterDecision, ball: BallObservation?) -> TouchDebugEvent { base.diagnostic(for: d, ball: ball) }
    func footEvidence(at i: Int) -> FootContactEvidence? {
        let original = base.footEvidence(at: i)
        if original?.confirms == true { return original }
        return auxiliaryFootEvidence(at: i) ?? original
    }
    func bind(to native: JugglingContactVerifier) {
        guard extendedContacts else { return }
        native.auxiliaryFootEvidence = { [weak self] in self?.auxiliaryFootEvidence(at: $0) }
    }
    func auxiliaryFootEvidence(at i: Int) -> FootContactEvidence? {
        var audit: [String: Any] = ["frame": i, "kind": "foot"]
        defer { if auditsEnabled, auditRows.count < 1024 { auditRows.append(audit) } }
        guard error == nil else { return nil }
        guard let contact = observations.frames.first(where: { $0.index == i }) else {
            return extendedContacts ? adjacentEvidence(at: i) : nil
        }
        guard
              let player = contact.player, player.state == .locked,
              let identity = player.id else { return nil }
        audit["timestampMs"] = contact.timestampMs
        let before = observations.frames.filter { (65...134).contains(contact.timestampMs-$0.timestampMs) }
            .min { abs(contact.timestampMs-$0.timestampMs-100) < abs(contact.timestampMs-$1.timestampMs-100) }
        let after = observations.frames.filter { (65...134).contains($0.timestampMs-contact.timestampMs) }
            .min { abs($0.timestampMs-contact.timestampMs-100) < abs($1.timestampMs-contact.timestampMs-100) }
        guard let before, let after else {
            audit["reason"] = "missing_exposure"
            return extendedContacts ? adjacentEvidence(at: i) : nil
        }
        let views = [before, contact, after]
        audit["people"] = views.map { $0.player?.peopleCount ?? 0 }
        let admitted = singlePersonControl
            ? views.allSatisfy { $0.player?.id == identity && $0.player?.state == .locked && $0.player?.peopleCount == 1 }
            : ToePlayerAssociation.sameObservedPlayer(views.map(\.player))
        guard admitted else { audit["reason"] = "player_window"; return nil }
        do {
            let samples = try views.map(sample)
            if auditsEnabled { audit["poses"] = views.map { poseAudit[$0.index] ?? [:] } }
            guard let a = samples[0], let b = samples[1], let c = samples[2] else {
                audit["reason"] = "pose_or_landmark_match"
                return extendedContacts ? adjacentEvidence(at: i) : nil
            }
            var evidence = FootContactEvidence(before: a, contact: b, after: c)
            evidence.usesFourExposureWindow = true
            if extendedContacts, !evidence.confirms {
                let samples = try expandedSamples(at: contact)
                let ground = GroundContactEvidence(contactMs: contact.timestampMs, samples: [])
                evidence.compactGroundEvidence = ToeGroundRecovery.augment(ground, with: samples,
                    imageAspect: Double(CVPixelBufferGetWidth(contact.pixels))/Double(CVPixelBufferGetHeight(contact.pixels)))
                if auditsEnabled { audit["expanded_samples"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samples)) }
            }
            audit["toe_confirms"] = evidence.confirms
            if auditsEnabled { audit["evidence"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) }
            if evidence.confirms { recoveries += 1 }
            return evidence.confirms ? evidence : (extendedContacts ? adjacentEvidence(at: i) : nil)
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func adjacentEvidence(at i: Int) -> FootContactEvidence? {
        guard error == nil, let proposed = observations.timestamp(at: i),
              let selected = observations.selection(at: i) else { return nil }
        let views = observations.frames.filter { abs($0.timestampMs-proposed) <= 167 }
        guard views.count <= 16 else { return nil }
        do {
            let samples = try views.compactMap { frame -> FootContactRules.Sample? in
                guard ToePlayerAssociation.sameObservedPlayer([selected, frame.player, selected]) else { return nil }
                return try sample(frame)
            }
            guard let result = AdjacentFootContactRules.measuredEvidence(samples, proposedMs: proposed),
                  abs(result.contact.timestampMs-proposed) <= 50,
                  let impact = views.first(where: { $0.timestampMs == result.contact.timestampMs }) else { return nil }
            // A shifted proof must pass the actual image's floor/hand/holding
            // checks as well as the proposal's downstream checks. No ball or
            // landmark is synthesized for the missing exposure.
            let ground = base.groundEvidence(at: impact.index, timed: true)
            let floor = ground?.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true) == true
                || ground?.unliftedFloorReboundMs != nil || ground?.corroboratedFloorReboundMs != nil
            let hand = base.rejectsHandContact(at: impact.index)
            let held = base.handlingEvidence(at: impact.index)?.state == .held
            if auditsEnabled, auditRows.count < 1024 {
                auditRows.append(["kind": "adjacent", "frame": i, "timestampMs": proposed,
                    "impact_frame": impact.index, "impact_ms": impact.timestampMs,
                    "floor": floor, "hand": hand, "held": held,
                    "evidence": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))])
            }
            guard !floor, !hand, !held else { return nil }
            return result
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func recoverGround(_ original: GroundContactEvidence?, at i: Int) -> GroundContactEvidence? {
        guard extendedContacts, error == nil, let original, original.visibleFootProof == nil,
              original.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true)
                || original.confirmsBallBesideFeet || original.needsPositiveFootContact
                || original.unliftedFloorReboundMs != nil || original.corroboratedFloorReboundMs != nil,
              let contact = observations.frames.first(where: { $0.index == i }),
              original.contactMs == contact.timestampMs else { return original }
        do {
            let samples = try expandedSamples(at: contact)
            let recovered = ToeGroundRecovery.augment(original, with: samples,
                imageAspect: Double(CVPixelBufferGetWidth(contact.pixels))/Double(CVPixelBufferGetHeight(contact.pixels)))
            if auditsEnabled, auditRows.count < 1024 {
                auditRows.append(["kind": "ground", "frame": i, "timestampMs": contact.timestampMs,
                    "recovered": recovered != nil,
                    "samples": try JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))])
            }
            return recovered ?? original
        } catch { self.error = error.localizedDescription; return original }
    }
    private func expandedSamples(at contact: ContactObservationStore.Frame) throws -> [FootContactRules.Sample] {
        let views = observations.frames.filter { abs($0.timestampMs-contact.timestampMs) <= 167 }
        guard views.count <= 16 else { return [] }
        return try views.compactMap { frame in
            guard ToePlayerAssociation.sameObservedPlayer([contact.player, frame.player, contact.player]) else { return nil }
            return try sample(frame)
        }
    }
    private func sample(_ frame: ContactObservationStore.Frame) throws -> FootContactRules.Sample? {
        // Prune even when inference yields no usable landmarks.
        let oldest = (observations.frames.last?.index ?? frame.index)-128
        cache = cache.filter { $0.key >= oldest }
        poseAudit = poseAudit.filter { $0.key >= oldest }
        attempted = Set(attempted.filter { $0 >= oldest })
        if attempted.contains(frame.index) { cacheHits += 1; return cache[frame.index] }
        attempted.insert(frame.index)
        let candidates: [[Landmark]]
        let key = try persistentKind.map { try PosePredictionStore.key(pixels:frame.pixels,kind:$0) }
        if let key, let saved = try observations.predictionStore?.lookup([[Landmark]].self,key:key) {
            candidates = saved
        } else {
            requests += 1
            let start = ProcessInfo.processInfo.systemUptime
            let result = try model().detect(image: MPImage(pixelBuffer: frame.pixels, orientation: .up))
            inferenceSeconds += ProcessInfo.processInfo.systemUptime-start
            let decoded = result.landmarks.filter { $0.count == 33 }.map { $0.map(Landmark.init) }
            if let key, let store = observations.predictionStore { candidates = try store.store(decoded,key:key) }
            else { candidates = decoded }
        }
        func point(_ points: [Landmark], _ index: Int) -> PoseLandmark? {
            let p = points[index]
            let x = Double(p.x), y = Double(p.y)
            let confidence = min(p.visibility ?? 0, p.presence ?? 0)
            guard x.isFinite, y.isFinite, confidence.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
            return .init(x: x, y: y, confidence: confidence)
        }
        let poses = candidates.map { points -> BodyPose in
            var pose = BodyPose()
            for (joint, index) in [(BodyJoint.nose, 0), (.leftShoulder, 11), (.rightShoulder, 12), (.leftHip, 23), (.rightHip, 24)] {
                if let p = point(points, index) { LiveBodyPoseRevision2.append(joint, x: p.x, visionY: 1-p.y, confidence: p.confidence, to: &pose) }
            }
            return pose
        }
        let selected = singlePersonControl
            ? ActivePlayerPoseMatcher.index(in: poses, selection: frame.player)
            : ToePlayerAssociation.index(in: poses, selection: frame.player)
        if auditsEnabled {
            poseAudit[frame.index] = ["frame": frame.index, "timestampMs": frame.timestampMs,
                "poses": poses.count, "selected": selected ?? -1]
        }
        guard let selected else { return nil }
        let points = candidates[selected]
        var toes: [BodySide: PoseLandmark] = [:], hips: [BodySide: PoseLandmark] = [:]
        for (side, toe, ankle, hip) in [(BodySide.left, 31, 27, 23), (.right, 32, 28, 24)] {
            if let t = point(points, toe), let a = point(points, ankle), let h = point(points, hip), t.confidence >= 0.7, a.confidence >= 0.5, h.confidence >= 0.7 {
                toes[side] = t; hips[side] = h
            }
        }
        let b = frame.ball
        let sample = FootContactRules.Sample(timestampMs: frame.timestampMs, ballX: b.x, ballY: b.y,
            width: b.width, height: b.height, confidence: b.score, ankles: toes, hips: hips)
        cache[frame.index] = sample
        return sample
    }
}
