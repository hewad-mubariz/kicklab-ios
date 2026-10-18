import Darwin
import Foundation

/// Non-overlapping stages of one live analysis frame. Counter time includes
/// lazy pose/contact checks; it must not be added to pose time a second time.
nonisolated struct LiveFramePerformance: Sendable {
    let totalMS: Double
    let motionMS: Double
    let contactBufferMS: Double
    let counterMS: Double
    let poseRequests: Int
    let handPoseRequests: Int
    let poseCacheHits: Int
}

/// Cumulative work, not recording wall time. Sampling this once a second keeps
/// short contact-check stalls visible even when they fall between HUD samples.
nonisolated struct LivePerformanceSummary: Codable, Sendable {
    var frames = 0
    var totalMS = 0.0
    var inferenceMS = 0.0
    var preprocessMS = 0.0
    var detectorMS = 0.0
    var motionMS = 0.0
    var contactBufferMS = 0.0
    var counterMS = 0.0
    var flushMS = 0.0
    var maxFrameMS = 0.0
    var framesOver33MS = 0
    var poseRequests = 0
    var handPoseRequests = 0
    var poseCacheHits = 0

    var meanFrameMS: Double { frames > 0 ? totalMS / Double(frames) : 0 }

    mutating func observe(_ frame: LiveFramePerformance, inference: Double, preprocessing: Double,
                          detector: Double) {
        frames += 1
        totalMS += frame.totalMS
        inferenceMS += inference
        preprocessMS += preprocessing
        detectorMS += detector
        motionMS += frame.motionMS
        contactBufferMS += frame.contactBufferMS
        counterMS += frame.counterMS
        maxFrameMS = max(maxFrameMS, frame.totalMS)
        if frame.totalMS > 1000 / 30 { framesOver33MS += 1 }
        // The verifier exposes cumulative request counts for this recording.
        poseRequests = frame.poseRequests
        handPoseRequests = frame.handPoseRequests
        poseCacheHits = frame.poseCacheHits
    }
}

nonisolated struct DetectorPerformanceSnapshot: Sendable {
    var model = "Not loaded"
    var computeBackend = "Not loaded"
    var inferenceMS = 0.0
    var preprocessMS = 0.0
    var totalMS = 0.0
    var p95MS = 0.0
    var memoryMB = 0.0
    var peakMemoryMB = 0.0
    var baselineMemoryMB = 0.0
    var modelLoadMS = 0.0
    var captureDrops = 0
    var processedFPS = 0.0
    var thermal = "nominal"
    var logURL: URL?
    var roiFullFrames = 0
    var roiCropFrames = 0
    var live: LivePerformanceSummary?
    var liveP95MS = 0.0
    var analysisTargetFPS = 30.0
    var analysisIdle = false
    var retainedMaskBytes = 0
}

/// Called only on the serial camera queue. Memory is the whole app's physical
/// footprint, not the model file size or a model-only allocation measurement.
nonisolated final class DetectorPerformance {
    private var samples: [Double] = []
    private var snapshot = DetectorPerformanceSnapshot()
    private var lastMemoryCheck = 0.0
    private var handle: FileHandle?
    private var framesSinceCheck = 0
    private var liveSamples: [Double] = []
    private(set) var liveSummary = LivePerformanceSummary()

    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func loaded(model: String, baselineMB: Double, milliseconds: Double, computeBackend: String = "Automatic") {
        try? handle?.close()
        handle = nil
        snapshot = DetectorPerformanceSnapshot()
        samples.removeAll(keepingCapacity: true)
        liveSamples.removeAll(keepingCapacity: true)
        liveSummary = LivePerformanceSummary()
        framesSinceCheck = 0
        lastMemoryCheck = ProcessInfo.processInfo.systemUptime
        snapshot.model = model
        snapshot.computeBackend = computeBackend
        snapshot.baselineMemoryMB = baselineMB
        snapshot.modelLoadMS = milliseconds
        #if DEBUG
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DetectorBenchmarks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("detector-\(UUID().uuidString).csv")
            let header = "# model=\(model),load_ms=\(milliseconds),baseline_app_mb=\(baselineMB),compute=\(computeBackend)\n" +
                "uptime_s,inference_ms,preprocess_ms,detector_total_ms,p95_total_ms,processed_fps,app_mb,peak_observed_app_mb,capture_drops,thermal,recording,live_frame_ms,live_p95_ms,motion_ms,contact_buffer_ms,counter_ms,pose_requests,hand_pose_requests,pose_cache_hits\n"
            try Data(header.utf8).write(to: url)
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
            snapshot.logURL = url
        } catch {
            snapshot.logURL = nil
        }
        #endif
    }

    func droppedFrame() { snapshot.captureDrops += 1 }

    func recordLiveFlush(milliseconds: Double) { liveSummary.flushMS += milliseconds }

    func finish() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    func observe(inferenceMS: Double, preprocessMS: Double, totalMS: Double, recording: Bool, captureDrops: Int? = nil,
                 roiFullFrames: Int = 0, roiCropFrames: Int = 0,
                 live: LiveFramePerformance? = nil) -> DetectorPerformanceSnapshot {
        if let captureDrops { snapshot.captureDrops = captureDrops }
        snapshot.roiFullFrames = roiFullFrames
        snapshot.roiCropFrames = roiCropFrames
        snapshot.inferenceMS = inferenceMS
        snapshot.preprocessMS = preprocessMS
        snapshot.totalMS = totalMS
        samples.append(totalMS)
        if let live {
            liveSummary.observe(live, inference: inferenceMS, preprocessing: preprocessMS, detector: totalMS)
            snapshot.live = liveSummary
            liveSamples.append(live.totalMS)
            if liveSamples.count > 120 { liveSamples.removeFirst(liveSamples.count - 120) }
        }
        framesSinceCheck += 1
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMemoryCheck >= 1 {
            snapshot.processedFPS = Double(framesSinceCheck) / (now - lastMemoryCheck)
            framesSinceCheck = 0
            lastMemoryCheck = now
            let ordered = samples.sorted()
            snapshot.p95MS = ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
            if !liveSamples.isEmpty {
                let ordered = liveSamples.sorted()
                snapshot.liveP95MS = ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
            }
            snapshot.memoryMB = Self.memoryMB()
            snapshot.peakMemoryMB = max(snapshot.peakMemoryMB, snapshot.memoryMB)
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: snapshot.thermal = "nominal"
            case .fair: snapshot.thermal = "fair"
            case .serious: snapshot.thermal = "serious"
            case .critical: snapshot.thermal = "critical"
            @unknown default: snapshot.thermal = "unknown"
            }
            #if DEBUG
            let row = "\(now),\(inferenceMS),\(preprocessMS),\(totalMS),\(snapshot.p95MS),\(snapshot.processedFPS),\(snapshot.memoryMB),\(snapshot.peakMemoryMB),\(snapshot.captureDrops),\(snapshot.thermal),\(recording),\(live?.totalMS ?? 0),\(snapshot.liveP95MS),\(live?.motionMS ?? 0),\(live?.contactBufferMS ?? 0),\(live?.counterMS ?? 0),\(live?.poseRequests ?? 0),\(live?.handPoseRequests ?? 0),\(live?.poseCacheHits ?? 0)\n"
            try? handle?.write(contentsOf: Data(row.utf8))
            #endif
        }
        return snapshot
    }

    deinit { try? handle?.close() }
}
