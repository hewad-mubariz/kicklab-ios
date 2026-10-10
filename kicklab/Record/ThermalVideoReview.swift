#if DEBUG
import Darwin
import SwiftUI

/// Opt-in, local-only endurance measurement using the production file analyzer.
/// No uploads, playback, synthetic detections or changes to user preferences.
struct ThermalVideoReview: View {
    let configurationURL: URL
    @State private var message = "Preparing thermal review…"
    @State private var started = false
    @State private var showOverlay = false
    @State private var overlayOnly = false
    @StateObject private var analyzer = VideoAnalyzer()

    private struct Configuration: Decodable {
        struct Clip: Decodable { let id: String; let file: String; let visualOnly: Bool }
        let rounds: Int
        let folder: String
        let cooldownSeconds: Double
        let clips: [Clip]
        let showOverlay: Bool?
        let overlayOnlySeconds: Double?
    }

    var body: some View {
        Group {
            if showOverlay {
                ProcessingOverlay(progress: overlayOnly ? 0.45 : analyzer.progress,
                    stepIndex: analyzer.progress < 0.85 ? 1 : 2,
                    statusMessage: analyzer.isCooling ? "Cooling down. Your video will continue automatically." : nil,
                    isPaused: analyzer.isCooling)
            } else {
                VStack(spacing: 20) {
                    Text("Video processing check").font(.title2)
                    Text(message).multilineTextAlignment(.center)
                    ProgressView(value: analyzer.progress)
                    Text("\(analyzer.framesRead) frames · \(analyzer.touchCount) touches")
                }.padding(30)
            }
        }.task { await run() }.onDisappear { analyzer.cancel() }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @MainActor private func run() async {
        guard !started else { return }; started = true
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        let oldBattery = UIDevice.current.isBatteryMonitoringEnabled
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = oldIdle
            UIDevice.current.isBatteryMonitoringEnabled = oldBattery
        }
        var folder: URL?
        do {
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configurationURL))
            overlayOnly = (config.overlayOnlySeconds ?? 0) > 0
            let destination = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: config.folder).lastPathComponent)
            folder = destination
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            func status(_ text: String) throws {
                message = text
                try Data(text.utf8).write(to: destination.appendingPathComponent("status.txt"), options: .atomic)
            }
            let coolingStart = ProcessInfo.processInfo.systemUptime
            var nominalSince: Double?
            while config.cooldownSeconds > 0 {
                let now = ProcessInfo.processInfo.systemUptime
                if ProcessInfo.processInfo.thermalState == .nominal { nominalSince = nominalSince ?? now }
                else { nominalSince = nil }
                if let nominalSince, now - nominalSince >= config.cooldownSeconds { break }
                guard now - coolingStart < 300 else { throw ReviewError.coolingTimeout }
                try status("COOLING · thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
                try await Task.sleep(for: .seconds(1))
            }
            // Cool on the quiet status screen; animating the measured overlay
            // during this period would itself change the starting conditions.
            showOverlay = config.showOverlay ?? false
            var rows = [[String: Any]]()
            var samples = [[String: Any]]()
            let overallStart = ProcessInfo.processInfo.systemUptime
            let overallCPU = cpuSeconds()
            func sample(_ clip: String, _ phase: String) {
                samples.append(["elapsed_s": ProcessInfo.processInfo.systemUptime - overallStart,
                    "cpu_s": cpuSeconds() - overallCPU, "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                    "memory_mib": DetectorPerformance.memoryMB(), "clip": clip, "phase": phase,
                    "frames": analyzer.framesRead, "battery": UIDevice.current.batteryLevel,
                    "battery_state": UIDevice.current.batteryState.rawValue])
            }
            func save(_ state: String) throws {
                let report: [String: Any] = ["status": state, "runs": rows, "samples": samples,
                    "elapsed_s": ProcessInfo.processInfo.systemUptime - overallStart,
                    "cpu_s": cpuSeconds() - overallCPU,
                    "device": UIDevice.current.model, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "cache_bypassed": ProcessInfo.processInfo.arguments.contains("--analysis-ignore-cache"),
                    "processing_overlay": showOverlay, "overlay_only": overlayOnly,
                    "legacy_overlay_cadence": ProcessInfo.processInfo.arguments.contains("--thermal-original-overlay"),
                    "scope": "Physical file analysis, same production frames/model/counter. iOS thermal pressure and process CPU time; not temperature, watts, live-camera or export measurement."]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination.appendingPathComponent("report.json"), options: .atomic)
            }
            if let duration = config.overlayOnlySeconds, duration > 0 {
                try status("OVERLAY ONLY")
                while ProcessInfo.processInfo.systemUptime - overallStart < min(90, duration) {
                    sample("overlay", "ui-only"); try save("running")
                    try await Task.sleep(for: .seconds(1))
                }
                try save("completed"); try status("COMPLETE")
                return
            }
            for round in 0..<min(4, max(1, config.rounds)) {
                for clip in config.clips {
                    try Task.checkCancellation()
                    let id = "\(round)-\(clip.id)"
                    try status("RUNNING \(id)")
                    let source = URL.documentsDirectory.appendingPathComponent(clip.file)
                    let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
                    let thermal = ProcessInfo.processInfo.thermalState.rawValue
                    analyzer.analyse(url: source, visualOnly: clip.visualOnly)
                    repeat {
                        sample(id, "analysis")
                        try save("running")
                        try await Task.sleep(for: .seconds(1))
                    } while analyzer.isRunning
                    guard analyzer.status == "done" else { throw ReviewError.analysis(analyzer.status) }
                    let end = ProcessInfo.processInfo.systemUptime
                    rows.append(["id": id, "source": clip.file, "visual_only": clip.visualOnly,
                        "elapsed_s": end - start, "cpu_s": cpuSeconds() - cpu,
                        "thermal_start": thermal, "thermal_end": ProcessInfo.processInfo.thermalState.rawValue,
                        "frames": analyzer.framesRead, "detections": analyzer.detections,
                        "count": analyzer.touchCount, "model": analyzer.analyzedModel,
                        "performance": analyzer.performance,
                        "touches": analyzer.recordedTouches.map { [$0.time, $0.x, $0.y] }])
                    // Retain exact output evidence only once per clip; measuring
                    // repeated imports must not accumulate large debug artifacts.
                    if round == 0 {
                        try SessionAnalysisStore.frameData(analyzer.recordedTrack)
                            .write(to: destination.appendingPathComponent("\(clip.id)-track.plist"))
                        if let trace = analyzer.counterTrace {
                            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                            try encoder.encode(trace).write(to: destination.appendingPathComponent("\(clip.id)-trace.plist"))
                        }
                    }
                    sample(id, "complete"); try save("running")
                }
            }
            try save("completed"); try status("COMPLETE")
        } catch {
            analyzer.cancel()
            await analyzer.waitUntilFinished()
            message = "FAILED: \(error)"
            if let folder { try? Data(message.utf8).write(to: folder.appendingPathComponent("status.txt"), options: .atomic) }
        }
    }
    private enum ReviewError: Error { case coolingTimeout, analysis(String) }
}
#endif
