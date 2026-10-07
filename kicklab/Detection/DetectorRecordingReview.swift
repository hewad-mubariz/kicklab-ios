import Darwin
import Foundation

/// Opt-in diagnostics saved only after a user-started recording finishes.
/// Keeps the existing raw movie, detected-ball timeline and counted contacts
/// available for lab review without burning app graphics into detector input.
nonisolated enum DetectorRecordingReview {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--detector-review")

    static func memory() -> (current: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        return result == KERN_SUCCESS
            ? (Double(info.phys_footprint), Double(info.ledger_phys_footprint_peak)) : nil
    }

    static var memoryGuardExceeded: Bool {
        enabled && (memory()?.peak ?? 0) > 350_000_000
    }

    static func save(video: URL?, model: String, threshold: Double, frames: Int,
                     count: Int, touches: [RecordedTouch], track: [RecordedFrame],
                     roiFullFrames: Int = 0, roiCropFrames: Int = 0,
                     handChecks: Int = 0, rejectedHands: Int = 0, handCheckError: String? = nil) {
        guard enabled, let video else { return }
        // Read the kernel lifetime peak before allocating the JSON export.
        let footprint = memory()
        var report: [String: Any] = [
            "model": model, "ball_threshold": threshold, "person_threshold": 0.5,
            "processed_frames": frames, "count": count,
            "roi_full_frames": roiFullFrames, "roi_crop_frames": roiCropFrames,
            "hand_check_enabled": JugglingContactVerifier.enabled,
            "hand_checks": handChecks, "rejected_hand_contacts": rejectedHands,
            "video_relative_path": "tmp/\(video.lastPathComponent)",
            "video_bytes": (try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
            "touches": touches.map {
                ["index": Double($0.index), "time": $0.time, "x": $0.x, "y": $0.y]
            },
            "detections": track.map {
                ["time": $0.time, "x": $0.x, "y": $0.y, "width": $0.width,
                 "height": $0.height, "score": $0.score, "vy": $0.vy]
            },
            "note": "Live native counter output, not ground-truth contacts. Detections include accepted ball frames only. Missing times are not interpolated. Raw movie has no burned-in counter. Kernel memory is measured at stop before JSON serialization; CSV contains recording samples. Recording may drop frames when writer is busy.",
        ]
        if let handCheckError { report["hand_check_error"] = handCheckError }
        if let footprint {
            report["stop_app_bytes"] = footprint.current
            report["kernel_lifetime_peak_bytes"] = footprint.peak
            report["within_300_MB"] = footprint.peak <= 300_000_000
            report["memory_guard_exceeded"] = footprint.peak > 350_000_000
        }
        do {
            let directory = FileManager.default.urls(for: .documentDirectory,
                in: .userDomainMask)[0].appendingPathComponent("DetectorReviews", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(video.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("json")
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                .write(to: file, options: .atomic)
        } catch {
            print("Detector recording review could not be saved: \(error.localizedDescription)")
        }
    }
}
