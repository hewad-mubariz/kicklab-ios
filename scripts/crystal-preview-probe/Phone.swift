import SwiftUI
import Metal

@main struct CrystalProbeApp: App {
    @State private var status = "Measuring Crystal's first use…"
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Crystal first-use check").font(.title2)
                Text(status).multilineTextAlignment(.center)
            }.padding().task {
                UIApplication.shared.isIdleTimerDisabled = true
                do {
                    if ProcessInfo.processInfo.arguments.contains("--baseline") {
                        try await Task.detached { try CrystalProbe.run() }.value
                    } else {
                        try await CrystalProbe.measurePreparation()
                    }
                    status = "Finished. Results saved locally."
                } catch { status = "Failed: \(error)" }
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}

enum CrystalProbe {
    @MainActor static func measurePreparation() async throws {
        let device = MTLCreateSystemDefaultDevice()!, library = device.makeDefaultLibrary()!
        let queue = device.makeCommandQueue()!
        let preparation = EffectResourcePreparation {
            let renderer = try CrystalLabRenderer(device: device, library: library)
            try renderer.warmUp(queue: queue)
            return renderer
        }
        let start = ProcessInfo.processInfo.systemUptime
        preparation.prepare()
        let requestMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var delays = [Double]()
        while preparation.resultIfReady == nil {
            let tick = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(8))
            delays.append(max(0, (ProcessInfo.processInfo.systemUptime - tick) * 1000 - 8))
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let first = try preparation.resultIfReady!.get()
        let reuseStart = ProcessInfo.processInfo.systemUptime
        let second = try preparation.resultIfReady!.get()
        let reuseMS = (ProcessInfo.processInfo.systemUptime - reuseStart) * 1000
        let report: [String: Any] = ["scope": "Production preparation and renderer, isolated optimized app. Main-actor heartbeat during first setup; not the whole editor.",
            "gpu": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "preview_level": CrystalLabRenderer.previewLevel(device: device),
            "request_main_ms": requestMS, "background_ready_ms": elapsed,
            "main_heartbeat_lateness_ms": delays, "main_heartbeat_max_lateness_ms": delays.max() ?? 0,
            "cached_read_main_ms": reuseMS, "shared_identity": first === second,
            "thermal_end": ProcessInfo.processInfo.thermalState.rawValue]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("crystal-preparation.json"))
    }

    // Original synchronous setup baseline. Kept for reproducing the before measurement.
    static func run() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let library = device.makeDefaultLibrary()!
        let queue = device.makeCommandQueue()!
        let startThermal = ProcessInfo.processInfo.thermalState.rawValue
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        func texture() -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 828, height: 1792, mipmapped: false)
            desc.usage = [.shaderRead, .renderTarget]
            return device.makeTexture(descriptor: desc)!
        }
        let source = texture(), target = texture()
        let clear = queue.makeCommandBuffer()!, pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = source
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.35, 0.4, 0.45, 1)
        clear.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
        clear.commit(); clear.waitUntilCompleted()
        var rows = [[String: Any]]()
        for attempt in 0..<3 {
            let start = now()
            let renderer = try CrystalLabRenderer(device: device, library: library)
            let setup = (now() - start) * 1000
            var frames = [[String: Double]]()
            for index in 0..<12 {
                let sceneStart = now(), time = 2.0 + Double(index) / 30
                let frame = CrystalFrame.make(time: time, size: CGSize(width: 828, height: 1792), strength: 1,
                    track: CrystalTrack(sample: { t in SIMD4(414 + sin(t * 2) * 55, 1000 + cos(t * 3) * 90, 30, 1) },
                                        touchTimes: [0.5, 1, 1.5, 2, 2.5]))
                let scene = (now() - sceneStart) * 1000
                let command = queue.makeCommandBuffer()!, encodeStart = now()
                try renderer.encode(frame: frame, source: source, target: target, command: command,
                                    previewLevel: CrystalLabRenderer.previewLevel(device: device))
                let encode = (now() - encodeStart) * 1000
                command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
                frames.append(["scene_ms": scene, "encode_ms": encode,
                    "gpu_ms": (command.gpuEndTime - command.gpuStartTime) * 1000,
                    "submit_and_wait_ms": (now() - encodeStart) * 1000])
            }
            rows.append(["attempt": attempt, "renderer_setup_ms": setup, "frames": frames])
        }
        let report: [String: Any] = ["scope": "Isolated optimized app using production Crystal sources. Measures setup and rendering, excludes the full editor, decoding and ball replacement.",
            "date": ISO8601DateFormatter().string(from: Date()), "gpu": device.name,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "thermal_start": startThermal, "thermal_end": ProcessInfo.processInfo.thermalState.rawValue,
            "preview_level": CrystalLabRenderer.previewLevel(device: device), "rows": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("crystal-first-use.json"))
    }
}
