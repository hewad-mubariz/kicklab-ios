#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// Fresh import through the production count, editor preparation and export path.
/// Profiling is observational; all caches and counting-prediction reuse stay enabled.
@MainActor
final class ImportedVideoPipelineBenchmark {
    private let analyzer = VideoAnalyzer()
    private let preparation = SessionEffectsPreparation()
    private var folder: URL?
    private var report: [String: Any] = [:]
    private var resources: [[String: Any]] = []
    private var phase = "Starting"
    private var fraction = 0.0
    private var measuredStart: Double?
    private var update: (String) -> Void = { _ in }

    func run(source: URL, update: @escaping (String) -> Void) async {
        self.update = update
        var sampler: Task<Void, Never>?
        defer { sampler?.cancel() }
        do {
            guard let name = SessionDesignReview.argument("--effects-folder") else { throw failure("Supply a fresh output folder") }
            let destination = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("Output folder already exists") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            folder = destination
            let info = try await VideoProcessingInfo.load(source)
            report = ["source": source.lastPathComponent, "duration": try await AVURLAsset(url: source).load(.duration).seconds,
                      "sourceDigest": try SessionAnalysisStore.sourceDigest(source), "fps": info.fps,
                      "system": UIDevice.current.systemVersion,
                      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                      "skin": "stealth", "style": "none", "shortEdge": 1080, "maxFrameRate": 60,
                      "scope": "Production foreground import, SessionEffectsPreparation, source spin, BallStyleBurnIn under normal video-work lease; transfer and Photos save excluded",
                      "cachePolicy": "Normal caches and prediction reuse; counting must be a cache miss"]
            UIDevice.current.isBatteryMonitoringEnabled = true
            sampler = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            try await cool()
            try FileManager.default.createDirectory(at: URL.documentsDirectory.appendingPathComponent("exact-clip-check"), withIntermediateDirectories: true)
            PreparationPerformance.reset()
            measuredStart = ProcessInfo.processInfo.systemUptime
            report["thermalStart"] = ProcessInfo.processInfo.thermalState.rawValue
            setPhase("Counting")
            let countStart = ProcessInfo.processInfo.systemUptime
            analyzer.analyse(url: source)
            await analyzer.waitUntilFinished()
            report["countSeconds"] = ProcessInfo.processInfo.systemUptime - countStart
            report["countPerformance"] = analyzer.performance
            report["count"] = analyzer.touchCount
            report["countFrames"] = analyzer.recordedTrack.count
            report["model"] = analyzer.analyzedModel
            guard analyzer.status == "done" else { throw failure("Counting: \(analyzer.status) \(analyzer.failureDiagnostic)") }
            guard analyzer.performance["cache_hit"] != 1 else { throw failure("Counting reused a completed analysis; not a fresh-import measurement") }
            try SessionAnalysisStore.frameData(analyzer.recordedTrack).write(to: destination.appendingPathComponent("counted-track.plist"))
            try write(analyzer.recordedTouches.map { ["time": $0.time, "x": $0.x, "y": $0.y] }, "counted-touches.json")
            if let trace = analyzer.counterTrace {
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(trace).write(to: destination.appendingPathComponent("counter-trace.plist"))
            }
            var summary = SessionSummary.make(touches: analyzer.touchCount, duration: analyzer.videoDuration,
                bestCombo: analyzer.touchCount, personalBest: analyzer.touchCount, videoURL: source,
                touchesMarked: analyzer.recordedTouches, track: analyzer.recordedTrack)
            if !analyzer.visualRecoveries.isEmpty { summary.visualTrack = analyzer.renderTrack }
            summary.framesUseCompositionClock = true
            summary.needsVisualPreparation = !summary.track.isEmpty
            var edit = SessionEditState(style: .none, intensity: 0)
            edit.ballSkin = .stealth
            let imported = summary
            let selectedEdit = edit
            let requiresGPU = selectedEdit.usesEffects || selectedEdit.usesLabSkin || selectedEdit.environment != .original
                || selectedEdit.scene != nil || (selectedEdit.usesBallMaterial && imported.needsVisualPreparation && preparation.prepared == nil)
            try await VideoBackgroundWork.shared.run(title: "Saving your replay", requiresGPU: requiresGPU) { @MainActor in
                self.setPhase("Preparing replacement masks")
                let prepStart = ProcessInfo.processInfo.systemUptime
                let ready = try await self.preparation.prepare(imported, for: selectedEdit, everyFrame: false)
                self.report["maskPreparationSeconds"] = ProcessInfo.processInfo.systemUptime - prepStart
                self.report["visualFrames"] = ready.renderTrack.count
                self.report["visualMasks"] = ready.renderTrack.filter { $0.ballMask != nil }.count
                guard ready.touches == imported.touches, ready.touchesMarked.map(\.time) == imported.touchesMarked.map(\.time) else {
                    throw self.failure("Visual preparation changed counting")
                }
                try SessionAnalysisStore.frameData(ready.renderTrack).write(to: destination.appendingPathComponent("visual-track.plist"))
                self.setPhase("Preparing source spin")
                let spinStart = ProcessInfo.processInfo.systemUptime
                let spinWorker = VideoWorkExecution.detached {
                    try await BallSurfaceTimeline.prepare(source: source, track: BallEffectTrack(frames: ready.renderTrack))
                }
                let spin = try await withTaskCancellationHandler { try await spinWorker.value } onCancel: { spinWorker.cancel() }
                self.report["spinSeconds"] = ProcessInfo.processInfo.systemUptime - spinStart
                self.report["spinEntries"] = spin.entries.count
                self.report["spinAccepted"] = spin.acceptedCount
                self.setPhase("Exporting")
                let exportStart = ProcessInfo.processInfo.systemUptime
                let worker = VideoWorkExecution.detached {
                    try await BallStyleBurnIn.render(source: source, track: ready.renderTrack,
                        style: .none, skin: .stealth, intensity: 0, shortEdge: 1080, maxFrameRate: 60) { progress in
                            VideoWorkExecution.lease?.progress(progress, subtitle: "Rendering your video")
                            await self.exportProgress(progress)
                        }
                }
                let output = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                self.report["exportSeconds"] = ProcessInfo.processInfo.systemUptime - exportStart
                try FileManager.default.moveItem(at: output, to: destination.appendingPathComponent("replacement.mp4"))
            }
            report["elapsedIncludingDiagnosticWritesSeconds"] = ProcessInfo.processInfo.systemUptime - (measuredStart ?? ProcessInfo.processInfo.systemUptime)
            report["totalSeconds"] = ["countSeconds", "maskPreparationSeconds", "spinSeconds", "exportSeconds"]
                .compactMap { report[$0] as? Double }.reduce(0, +)
            report["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
            report["thermalPeak"] = resources.filter { ($0["elapsed"] as? Double ?? -1) >= 0 }.compactMap { $0["thermal"] as? Int }.max() ?? 0
            report["sampledPeakMemoryMB"] = resources.compactMap { $0["memoryMB"] as? Double }.max() ?? 0
            setPhase("Done")
            try save()
        } catch {
            report["error"] = String(reflecting: error)
            setPhase("Failed: \(error.localizedDescription)")
            try? save()
        }
    }

    private func cool() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        var nominalSince: Double?
        setPhase("Cooling before measurement")
        while ProcessInfo.processInfo.systemUptime - started < 600 {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            if ProcessInfo.processInfo.thermalState == .nominal {
                if nominalSince == nil { nominalSince = now }
                if now - (nominalSince ?? now) >= 10 { return }
            } else { nominalSince = nil }
            try await Task.sleep(for: .seconds(1))
        }
        throw failure("Phone did not cool to nominal temperature")
    }

    private func setPhase(_ value: String) { phase = value; fraction = 0; update(value); sample() }
    private func exportProgress(_ value: Double) { fraction = value }
    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let progress = phase == "Counting" ? analyzer.progress : phase == "Preparing replacement masks" ? preparation.progress : fraction
        let row: [String: Any] = ["time": Date().timeIntervalSince1970, "elapsed": measuredStart.map { now - $0 } ?? -1,
            "phase": phase, "progress": progress, "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            "appState": UIApplication.shared.applicationState.rawValue, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "battery": UIDevice.current.batteryLevel, "batteryState": UIDevice.current.batteryState.rawValue,
            "memoryMB": DetectorPerformance.memoryMB()]
        resources.append(row)
        try? write(row, "status.json")
        if resources.count.isMultiple(of: 10) { try? save() }
        if phase == "Counting" || phase == "Preparing replacement masks" || phase == "Exporting" {
            update("\(phase) · \(Int(progress * 100))%")
        }
    }
    private func save() throws {
        report["phase"] = phase
        try write(report, "report.json")
        try write(resources, "resources.json")
        if let folder, let data = try? Data(contentsOf: URL.documentsDirectory.appendingPathComponent("exact-clip-check/preparation-stages.json")) {
            try data.write(to: folder.appendingPathComponent("preparation-stages.json"), options: .atomic)
        }
    }
    private func write(_ value: Any, _ name: String) throws {
        guard let folder else { return }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(name), options: .atomic)
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "ImportedVideoPipelineBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
