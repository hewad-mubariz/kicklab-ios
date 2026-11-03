#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// Opt-in physical-phone ABBA comparison. Uses the shipping exporter and lease;
/// identical retained observations and a prepared source-spin timeline in both arms.
@MainActor
final class BallSkinExportBenchmark {
    private var report: [String: Any] = [:]
    private var rows: [[String: Any]] = []
    private var folder: URL?
    private var peakThermal = 0
    private var update: (String) -> Void = { _ in }

    func run(source: URL, update: @escaping (String) -> Void) async {
        self.update = update
        do {
            guard let path = SessionDesignReview.argument("--effects-owned-track"),
                  let name = SessionDesignReview.argument("--effects-folder") else {
                throw failure("Supply an owned track and a fresh output folder")
            }
            let destination = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("Output folder already exists") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            folder = destination
            let stored = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf: SessionDesignReview.fileURL(path)))
            guard !stored.isEmpty, stored.allSatisfy(\.isValid) else { throw failure("Invalid retained observations") }
            let frames = stored.map(\.frame)
            let duration = try await AVURLAsset(url: source).load(.duration).seconds
            report = ["source": source.lastPathComponent, "duration": duration, "trackFrames": frames.count,
                      "skin": "arctic", "effect": "none", "shortEdge": 1080, "maxFrameRate": 60,
                      "system": UIDevice.current.systemVersion, "device": UIDevice.current.model,
                      "order": ["cpu-1", "gpu-1", "gpu-2", "cpu-2"],
                      "scope": "Complete foreground exports; retained tracking; source-spin preparation excluded; normal image-work lease policy; audio included"]
            try record("Preparing source spin")
            let preparationStart = ProcessInfo.processInfo.systemUptime
            let timeline = try await BallSurfaceTimeline.prepare(source: source, track: BallEffectTrack(frames: frames))
            report["preparationSeconds"] = ProcessInfo.processInfo.systemUptime - preparationStart
            report["spinEntries"] = timeline.entries.count
            report["spinAccepted"] = timeline.acceptedCount
            // Initialize both material backends outside the timed section. Clear pose
            // images before every arm so the second arm cannot reuse the first's raster.
            _ = BallSkinMetalRenderer.$forceCPUForReview.withValue(true) {
                BallSkinSphereRenderer.uncachedImageForReview(skin: .arctic, time: 0)
            }
            guard BallSkinMetalRenderer.isAllowed else { throw failure("Foreground artwork GPU access unavailable") }
            let warmDraws = BallSkinMetalRenderer.shared?.completedDrawsForReview ?? 0
            _ = BallSkinSphereRenderer.uncachedImageForReview(skin: .arctic, time: 0)
            guard (BallSkinMetalRenderer.shared?.completedDrawsForReview ?? 0) > warmDraws else { throw failure("GPU warmup fell back to CPU") }

            for (name, cpu) in [("cpu-1", true), ("gpu-1", false), ("gpu-2", false), ("cpu-2", true)] {
                try await cool(name: name)
                BallSkinSphereRenderer.clearImageCacheForReview()
                peakThermal = ProcessInfo.processInfo.thermalState.rawValue
                let thermalStart = peakThermal
                let drawsBefore = BallSkinMetalRenderer.shared?.completedDrawsForReview ?? 0
                try record("Exporting \(name)")
                let started = ProcessInfo.processInfo.systemUptime
                let result = try await VideoBackgroundWork.shared.run(title: "Ball export comparison", requiresGPU: false) {
                    let worker = VideoWorkExecution.detached {
                        try await BallSkinMetalRenderer.$forceCPUForReview.withValue(cpu) {
                            let imageCPUOnly = VideoWorkExecution.cpuOnly
                            let gpuAllowed = BallSkinMetalRenderer.isAllowed
                            let movie = try await BallStyleBurnIn.render(source: source, track: frames, style: .none, skin: .arctic,
                                intensity: 0, shortEdge: 1080, maxFrameRate: 60) { progress in
                                    VideoWorkExecution.lease?.progress(progress, subtitle: "Exporting \(name)")
                                    await self.progress(progress, name: name)
                                }
                            return (movie, imageCPUOnly, gpuAllowed)
                        }
                    }
                    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let draws = (BallSkinMetalRenderer.shared?.completedDrawsForReview ?? 0) - drawsBefore
                let output = destination.appendingPathComponent(name + "." + result.0.pathExtension)
                try FileManager.default.moveItem(at: result.0, to: output)
                rows.append(["name": name, "cpu": cpu, "seconds": elapsed,
                             "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
                             "thermalPeak": peakThermal, "gpuDraws": draws, "gpuAllowedAtStart": result.2,
                             "imageCPUOnly": result.1, "output": output.lastPathComponent])
                try record("Finished \(name)")
                guard cpu ? draws == 0 : draws > 0 else { throw failure("Unexpected renderer in \(name)") }
            }
            try record("Done")
        } catch {
            report["error"] = String(describing: error)
            try? record("Failed: \(error.localizedDescription)")
            update("Failed: \(error.localizedDescription)")
        }
    }

    private func cool(name: String) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        var nominalSince: Double?
        while ProcessInfo.processInfo.systemUptime - start < 180 {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            if ProcessInfo.processInfo.thermalState == .nominal {
                if nominalSince == nil { nominalSince = now }
                if now - (nominalSince ?? now) >= 10 { return }
            } else { nominalSince = nil }
            try record("Cooling before \(name)")
            try await Task.sleep(for: .seconds(1))
        }
        throw failure("Phone did not return to nominal temperature before \(name)")
    }

    private func progress(_ value: Double, name: String) {
        peakThermal = max(peakThermal, ProcessInfo.processInfo.thermalState.rawValue)
        try? record("Exporting \(name)", progress: value)
    }

    private func record(_ phase: String, progress: Double = 0) throws {
        update(phase)
        report["phase"] = phase; report["progress"] = progress; report["runs"] = rows
        report["thermalNow"] = ProcessInfo.processInfo.thermalState.rawValue
        report["updatedAt"] = Date().timeIntervalSince1970
        if let folder {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BallExportBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
