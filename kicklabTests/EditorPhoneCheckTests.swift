import AVFoundation
import CoreVideo
import Metal
import XCTest
@testable import kicklab

/// Phone check for the editor upgrade: export time and per-frame preview cost with Looks,
/// sounds and a Broadcast timer, against one plain look. Uses the juggling fixture, the
/// current detector for the ball track and the labelled touch times. Run on the phone;
/// results print as "PHONECHECK" lines and save to Documents/editor-phone-check.json.
final class EditorPhoneCheckTests: XCTestCase {
    private var report: [String: Any] = [:]

    private func note(_ key: String, _ value: Any) {
        report[key] = value
        print("PHONECHECK \(key) = \(value)")
    }

    @MainActor
    func testEditorUpgradeCostOnThisPhone() async throws {
        let bundle = Bundle(for: Self.self)
        let video = try XCTUnwrap(bundle.url(forResource: "juggling-eighteen", withExtension: "mov"))
        let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(
            bundle.url(forResource: "juggling-eighteen-events", withExtension: "json")))) as! [String: Any]
        let touches = (labels["events"] as! [[String: Any]]).filter { $0["counts"] as? Bool == true }
            .map { $0["time_s"] as! Double }.sorted()
        #if targetEnvironment(simulator)
        note("hardware", "simulator")
        #else
        var system = utsname(); uname(&system)
        note("hardware", withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        #endif
        note("thermal_start", ProcessInfo.processInfo.thermalState.rawValue)
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        note("clip_seconds", duration)
        note("touches", touches.count)

        // Ball track with the current detector, as the effects preparation finds positions.
        let trackStart = ProcessInfo.processInfo.systemUptime
        let frames = try await track(video)
        note("track_seconds", ProcessInfo.processInfo.systemUptime - trackStart)
        note("track_frames", frames.count)
        XCTAssertGreaterThan(frames.count, 200, "The detector should find the ball through most of the clip")

        var overlays = ExportOverlaySettings()
        overlays.counter.enabled = true
        let counter = ExportCounterTimeline(touches: touches.enumerated().map {
            RecordedTouch(index: $0.offset, time: $0.element, x: 0.5, y: 0.5)
        }, total: touches.count)

        // Plain: one look, Pill timer, no added sounds.
        let plain = SessionEditState(style: .glowTrail, intensity: 0.85)
        // Upgrade: Power-up looks with prints, Burst changes, touch sounds, muted original, Broadcast timer.
        var upgraded = SessionEditState(style: .glowTrail, intensity: 0.85)
        let recipe = LookRecipes.make(.powerUp, base: upgraded.baseLook, touchCount: touches.count)
        upgraded.lookChanges = recipe.changes
        upgraded.swapEffect = recipe.moment
        upgraded.touchSound = .pop
        upgraded.clipAudio = false
        note("looks", upgraded.runStarts.count)
        // What a single heavy look already cost before this branch: Lava with Fire on every touch.
        let single = SessionEditState(style: .fire, intensity: 0.85, ballSkin: .lava)
        // The recipe this phone class now gets.
        var light = upgraded
        light.lookChanges = LookRecipes.make(.powerUp, base: light.baseLook, touchCount: touches.count, lightweight: true).changes

        for (name, edit, timer) in [("plain", plain, TimerStyle.pill), ("single", single, TimerStyle.pill),
                                    ("upgrade", upgraded, TimerStyle.broadcast), ("upgrade_light", light, TimerStyle.broadcast)] {
            var settings = overlays
            settings.timer.style = timer
            let start = ProcessInfo.processInfo.systemUptime
            let output = try await BallStyleBurnIn.render(source: video, track: frames, style: edit.style,
                skin: edit.ballSkin, intensity: edit.intensity, shortEdge: 1080, counter: counter, overlays: settings,
                lookChanges: edit.lookChanges, swapEffect: edit.swapEffect,
                soundtrack: ReplaySoundtrack(edit: edit, touchTimes: touches), clipAudio: edit.clipAudio)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            try? FileManager.default.removeItem(at: output)
            note("export_\(name)_seconds", seconds)
            note("export_\(name)_x_realtime", seconds / duration)

            let preview = try await previewCost(video: video, frames: frames, touches: touches, edit: edit, timer: timer)
            note("preview_\(name)_cpu_ms_p50", preview.cpu.p50)
            note("preview_\(name)_cpu_ms_p95", preview.cpu.p95)
            note("preview_\(name)_gpu_ms_p50", preview.gpu.p50)
            note("preview_\(name)_gpu_ms_p95", preview.gpu.p95)
            note("preview_\(name)_frames_over_33ms", preview.over33)
            for (part, values) in preview.parts.sorted(by: { $0.key < $1.key }) {
                note("part_\(name)_\(part)_ms_p50_p95", "\(values.p50) / \(values.p95)")
            }
        }
        note("thermal_end", ProcessInfo.processInfo.thermalState.rawValue)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("editor-phone-check.json"), options: .atomic)
    }

    /// GPU cost of every effect on this phone over the whole clip, so recipes can pick smooth ones.
    @MainActor
    func testEffectCostOnThisPhone() async throws {
        let bundle = Bundle(for: Self.self)
        let video = try XCTUnwrap(bundle.url(forResource: "juggling-eighteen", withExtension: "mov"))
        let frames = try await track(video)
        let effects = BallEffectTrack(frames: frames)
        let engine = try MetalEffectEngine()
        let asset = AVURLAsset(url: video)
        let videoTrack = try await asset.loadTracks(withMediaType: .video)[0]
        for style in BallStyle.selectableCases where style != .none {
            let edit = SessionEditState(style: style, intensity: 0.85)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var costs: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                let start = ProcessInfo.processInfo.systemUptime
                try engine.composite(EffectFrame.video(size: size, sourceSize: size, edit: edit, track: effects, time: time),
                                     pixelBuffer: pixels)
                costs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            let sorted = costs.sorted()
            note("effect_\(style.rawValue)_gpu_ms_p50_p95", "\(sorted[sorted.count / 2]) / \(sorted[Int(Double(sorted.count) * 0.95)])")
        }
        note("thermal_end", ProcessInfo.processInfo.thermalState.rawValue)
    }

    // MARK: - Ball track

    @MainActor
    private func track(_ video: URL) async throws -> [RecordedFrame] {
        let asset = AVURLAsset(url: video)
        let videoTrack = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let detector = try BallDetector()
        var association = BallPlausibility(policy: detector.plausibilityPolicy)
        var frames: [RecordedFrame] = [], index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let found = try autoreleasepool { try detector.effectPosition(in: pixels) }
            guard let found, let ball = association.accept(found, frame: index, timestampMs: Int(time * 1000)) else { continue }
            frames.append(RecordedFrame(time: time, x: ball.x, y: ball.y, width: ball.width, height: ball.height,
                score: ball.score, smoothedX: ball.x, smoothedY: ball.y, vy: 0, motion: .unknown, detected: true, person: nil))
        }
        return frames
    }

    // MARK: - Preview

    private struct Spread { let p50: Double; let p95: Double }

    /// The replay's per-frame work at the iPhone 11 Pro Max drawable size: the ball print and
    /// change moment on the material canvas, the counter and timer images (CPU), and the effect
    /// pass on the GPU, for every decoded frame.
    @MainActor
    private func previewCost(video: URL, frames: [RecordedFrame], touches: [Double], edit: SessionEditState,
                             timer: TimerStyle) async throws -> (cpu: Spread, gpu: Spread, over33: Int, parts: [String: Spread]) {
        var effects = BallEffectTrack(frames: frames, touchTimes: touches)
        if edit.usesBallMaterial {
            effects.surfaceMotion = try await BallSurfaceTimeline.prepare(source: video, track: effects)
        }
        let swaps = BallSwapTimeline(edit: edit, touchTimes: effects.touches)
        let canvas = CGSize(width: 828, height: 1792)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
            bytesPerRow: Int(canvas.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.translateBy(x: 0, y: canvas.height); context.scaleBy(x: 1, y: -1)
        let engine = try MetalEffectEngine()
        let counter = ExportCounterTimeline(touches: touches.enumerated().map {
            RecordedTouch(index: $0.offset, time: $0.element, x: 0.5, y: 0.5)
        }, total: touches.count)

        let asset = AVURLAsset(url: video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try await asset.loadTracks(withMediaType: .video)[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var cpu: [Double] = [], gpu: [Double] = []
        var parts: [String: [Double]] = [:]
        func lap(_ name: String, _ start: inout Double) {
            let now = ProcessInfo.processInfo.systemUptime
            parts[name, default: []].append((now - start) * 1000)
            start = now
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let source = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            let cpuStart = ProcessInfo.processInfo.systemUptime
            var mark = cpuStart
            autoreleasepool {
                context.clear(CGRect(origin: .zero, size: canvas))
                lap("clear", &mark)
                let skin = edit.ballSkin(at: time, touchTimes: effects.touches)
                let swap = swaps.active(at: time)
                let guide = effects.replacementGuide(at: time)
                var replacement: BallMaterialRenderer.Replacement?
                if skin != .original, let guide {
                    let fitted = BallReplacementFootprint.fit(pixels: pixels, sample: guide, measureTexture: true)
                    let smear = effects.smear(at: time, size: source)
                    replacement = BallMaterialRenderer.replacement(footprint: fitted, skin: skin, time: time,
                        orientation: effects.surfaceMotion?.renderOrientation(at: time), smear: smear,
                        light: effects.surfaceMotion?.light(at: time))
                }
                lap("print", &mark)
                BallMaterialRenderer.draw(in: context, size: canvas, sourceSize: source, skin: skin,
                    sample: replacement == nil ? nil : guide, time: time, replacement: replacement,
                    scale: swap.map { swaps.effect.ballScale(age: $0.age) } ?? 1)
                lap("print_draw", &mark)
                if let swap, let at = guide ?? effects.sample(at: time) {
                    let geometry = BallMaterialRenderer.outputGeometry(size: canvas, sourceSize: source, sample: at)
                    BallSwapRenderer.draw(in: context, center: geometry.center, radius: geometry.radius,
                                          effect: swaps.effect, age: swap.age, event: swap.event)
                }
                lap("change", &mark)
                _ = TimerOverlayAppearance.image(style: timer, time: time)
                lap("timer", &mark)
                _ = ExportOverlayRenderer.image(style: .normal, time: time, counter: counter.state(at: time))
                lap("counter", &mark)
            }
            cpu.append((ProcessInfo.processInfo.systemUptime - cpuStart) * 1000)
            let gpuStart = ProcessInfo.processInfo.systemUptime
            let frame = EffectFrame.video(size: source, sourceSize: source, edit: edit, track: effects, time: time)
            try engine.composite(frame, pixelBuffer: pixels)
            gpu.append((ProcessInfo.processInfo.systemUptime - gpuStart) * 1000)
            let effect = edit.effect(at: time, touchTimes: effects.touches)
            parts["gpu_\(effect.rawValue)", default: []].append(gpu.last!)
        }
        func spread(_ values: [Double]) -> Spread {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return Spread(p50: 0, p95: 0) }
            return Spread(p50: sorted[sorted.count / 2], p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        }
        let over = zip(cpu, gpu).filter { $0 + $1 > 33.3 }.count
        return (spread(cpu), spread(gpu), over, parts.mapValues(spread))
    }
}
