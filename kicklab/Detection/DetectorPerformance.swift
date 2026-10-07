import Darwin
import Foundation

nonisolated struct DetectorPerformanceSnapshot: Sendable {
    var model = "Not loaded"
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
}

/// Called only on the serial camera queue. Memory is the whole app's physical
/// footprint, not the model file size or a model-only allocation measurement.
nonisolated final class DetectorPerformance {
    private var samples: [Double] = []
    private var snapshot = DetectorPerformanceSnapshot()
    private var lastMemoryCheck = 0.0
    private var handle: FileHandle?
    private var framesSinceCheck = 0

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

    func loaded(model: String, baselineMB: Double, milliseconds: Double) {
        try? handle?.close()
        handle = nil
        snapshot = DetectorPerformanceSnapshot()
        samples.removeAll(keepingCapacity: true)
        framesSinceCheck = 0
        lastMemoryCheck = ProcessInfo.processInfo.systemUptime
        snapshot.model = model
        snapshot.baselineMemoryMB = baselineMB
        snapshot.modelLoadMS = milliseconds
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DetectorBenchmarks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("detector-\(UUID().uuidString).csv")
            let header = "# model=\(model),load_ms=\(milliseconds),baseline_app_mb=\(baselineMB)\n" +
                "uptime_s,inference_ms,preprocess_ms,detector_total_ms,p95_total_ms,processed_fps,app_mb,peak_observed_app_mb,capture_drops,thermal,recording\n"
            try Data(header.utf8).write(to: url)
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
            snapshot.logURL = url
        } catch {
            snapshot.logURL = nil
        }
    }

    func droppedFrame() { snapshot.captureDrops += 1 }

    func finish() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    func observe(inferenceMS: Double, preprocessMS: Double, totalMS: Double, recording: Bool,
                 roiFullFrames: Int = 0, roiCropFrames: Int = 0) -> DetectorPerformanceSnapshot {
        snapshot.roiFullFrames = roiFullFrames
        snapshot.roiCropFrames = roiCropFrames
        snapshot.inferenceMS = inferenceMS
        snapshot.preprocessMS = preprocessMS
        snapshot.totalMS = totalMS
        samples.append(totalMS)
        framesSinceCheck += 1
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMemoryCheck >= 1 {
            snapshot.processedFPS = Double(framesSinceCheck) / (now - lastMemoryCheck)
            framesSinceCheck = 0
            lastMemoryCheck = now
            let ordered = samples.sorted()
            snapshot.p95MS = ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
            snapshot.memoryMB = Self.memoryMB()
            snapshot.peakMemoryMB = max(snapshot.peakMemoryMB, snapshot.memoryMB)
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: snapshot.thermal = "nominal"
            case .fair: snapshot.thermal = "fair"
            case .serious: snapshot.thermal = "serious"
            case .critical: snapshot.thermal = "critical"
            @unknown default: snapshot.thermal = "unknown"
            }
            let row = "\(now),\(inferenceMS),\(preprocessMS),\(totalMS),\(snapshot.p95MS),\(snapshot.processedFPS),\(snapshot.memoryMB),\(snapshot.peakMemoryMB),\(snapshot.captureDrops),\(snapshot.thermal),\(recording)\n"
            try? handle?.write(contentsOf: Data(row.utf8))
        }
        return snapshot
    }

    deinit { try? handle?.close() }
}
