import AVFoundation
import Darwin
import Foundation
import UIKit

/// Opt-in developer experiment on the actual RecordView, without XCTest or
/// debugger overhead. Ordinary launches never start recording automatically.
enum DetectorPhoneBenchmark {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("--detector-benchmark")
    }

    private static func footprint() -> (bytes: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (Double(info.phys_footprint), Double(info.ledger_phys_footprint_peak)) : (0, 0)
    }

    @MainActor
    static func run(camera: CameraSession) async {
        guard requested else { return }
        let arguments = ProcessInfo.processInfo.arguments
        func option(_ name: String) -> String? {
            arguments.first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
        }
        let seconds = min(600, max(10, Double(option("--benchmark-seconds") ?? "30") ?? 30))
        let cycles = min(10, max(1, Int(option("--benchmark-cycles") ?? "1") ?? 1))
        let runID = option("--benchmark-id")?.filter { $0.isLetter || $0.isNumber || $0 == "-" } ?? ""
        for cycle in 1...cycles {
            guard !Task.isCancelled else { return }
            let suffix = runID.isEmpty && cycles == 1 ? "" : "-\(runID)-cycle-\(cycle)"
            let completed = await runCycle(camera: camera, seconds: seconds, suffix: suffix, cycle: cycle)
            if !completed { return }
        }
    }

    @MainActor
    private static func runCycle(camera: CameraSession, seconds: Double, suffix: String, cycle: Int) async -> Bool {
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        let resource = BallDetector.configuredResourceName
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DetectorBenchmarks", isDirectory: true)
        let variant = ProcessInfo.processInfo.arguments.contains("--yolox-roi") ? "-roi-v3" : ""
        let reportURL = folder.appendingPathComponent("\(resource)\(variant)\(suffix)-phone.json")
        var rows: [[String: Any]] = []
        var report: [String: Any] = [
            "status": "starting", "model": resource,
            "variant": variant,
            "memory_budget_bytes": 300_000_000, "early_stop_bytes": 350_000_000,
            "target_recording_seconds": seconds, "cycle": cycle,
            "device": UIDevice.current.model, "system_version": UIDevice.current.systemVersion,
            "runtime": "App with actual RecordView/live preview/HUD, no XCTest/debugger; see run build configuration",
            "measurement": "Whole app physical footprint sampled every 50 ms, plus kernel lifetime footprint peak; decimal MB = bytes/1e6.",
        ]
        func save() throws {
            report["samples"] = rows
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        let began = ProcessInfo.processInfo.systemUptime
        var peakSampled = 0.0
        var kernelPeak = 0.0
        func sample(_ phase: String) {
            let memory = footprint()
            peakSampled = max(peakSampled, memory.bytes)
            kernelPeak = max(kernelPeak, memory.peak)
            rows.append([
                "elapsed_s": ProcessInfo.processInfo.systemUptime - began,
                "phase": phase, "memory_bytes": memory.bytes, "kernel_peak_bytes": memory.peak,
                "processed_frames": camera.processedFrames, "recording": camera.isRecording,
                "inference_ms": camera.performance.inferenceMS,
                "detector_ms": camera.performance.totalMS,
                "p95_detector_ms": camera.performance.p95MS,
                "preprocess_ms": camera.performance.preprocessMS,
                "fps": camera.performance.processedFPS,
                "capture_drops": camera.performance.captureDrops,
                "roi_full_frames": camera.performance.roiFullFrames,
                "roi_crop_frames": camera.performance.roiCropFrames,
                "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                "application_state": UIApplication.shared.applicationState.rawValue,
            ])
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try save()
            let deadline = Date().addingTimeInterval(15)
            while !camera.isReady, Date() < deadline {
                sample("preview_startup")
                try await Task.sleep(for: .milliseconds(50))
            }
            guard camera.isReady else { throw NSError(domain: "BenchmarkCameraUnavailable", code: 1) }
            // Verify normal preview has no loaded detector or recording work.
            let previewFrames = camera.processedFrames
            for _ in 0..<20 {
                sample("preview")
                try await Task.sleep(for: .milliseconds(50))
            }
            report["preview_detection_off"] = camera.processedFrames == previewFrames && camera.performance.model == "Not loaded"
            report["preview_memory_bytes"] = footprint().bytes
            camera.startRecording()
            let startup = ProcessInfo.processInfo.systemUptime
            var recordingStart: Double?
            var stopReason = "duration_completed"
            var lastSave = startup
            repeat {
                try await Task.sleep(for: .milliseconds(50))
                let now = ProcessInfo.processInfo.systemUptime
                if camera.isRecording, recordingStart == nil { recordingStart = now }
                sample(camera.isRecording ? "recording" : "model_startup")
                if now - lastSave >= 1 {
                    report["status"] = "running"
                    try save()
                    lastSave = now
                }
                if max(peakSampled, kernelPeak) > 350_000_000 { stopReason = "memory_guard"; break }
                if recordingStart != nil && (!camera.isRecording || UIApplication.shared.applicationState != .active) {
                    stopReason = "recording_interrupted"; break
                }
                if let error = camera.recordingError ?? camera.detectorError {
                    report["error"] = error; stopReason = "pipeline_error"; break
                }
                if let start = recordingStart, now - start >= seconds { break }
                if recordingStart == nil, now - startup > 45 { stopReason = "startup_timeout"; break }
            } while !Task.isCancelled
            if Task.isCancelled { stopReason = "cancelled" }
            let processed = camera.processedFrames
            report["roi_full_frames"] = camera.performance.roiFullFrames
            report["roi_crop_frames"] = camera.performance.roiCropFrames
            report["model_load_ms"] = camera.performance.modelLoadMS
            report["csv_file"] = camera.performance.logURL?.lastPathComponent
            camera.stopRecording()
            let finish = Date().addingTimeInterval(10)
            while camera.isFinishingRecording, Date() < finish {
                sample("finishing")
                try await Task.sleep(for: .milliseconds(50))
            }
            for _ in 0..<100 {
                sample("after_stop_preview")
                try await Task.sleep(for: .milliseconds(50))
            }
            report["status"] = stopReason == "duration_completed" ? "completed" : "failed"
            report["stop_reason"] = stopReason
            report["peak_sampled_app_bytes"] = peakSampled
            report["kernel_lifetime_peak_bytes"] = kernelPeak
            report["within_300_MB"] = max(peakSampled, kernelPeak) <= 300_000_000
            report["processed_frames"] = processed
            report["after_stop_memory_bytes"] = footprint().bytes
            report["recording_finished"] = !camera.isFinishingRecording
            report["detection_stopped"] = camera.processedFrames == processed && camera.performance.model == "Not loaded"
            if let file = camera.recordingURL {
                report["video_duration_s"] = try await AVURLAsset(url: file).load(.duration).seconds
                // Only the benchmark-created temporary recording is removed.
                try? FileManager.default.removeItem(at: file)
                camera.clearRecording()
            }
            try save()
            print("DETECTOR_PHONE_BENCHMARK \(resource) sampled=\(peakSampled / 1e6) MB kernelPeak=\(kernelPeak / 1e6) MB frames=\(processed) stop=\(stopReason)")
            return stopReason == "duration_completed" && !camera.isFinishingRecording
        } catch {
            camera.stopRecording()
            report["status"] = "failed"
            report["error"] = error.localizedDescription
            try? save()
            return false
        }
    }
}
