import AVFoundation
import MetalKit
import SwiftUI

/// Video and effects share a decoded frame's timestamp and one GPU presentation.
/// The player's periodic observer is only responsible for the transport UI.
struct MetalVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let edit: SessionEditState
    let track: BallEffectTrack
    var onFailure: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> EffectVideoView { EffectVideoView() }
    func updateUIView(_ view: EffectVideoView, context: Context) {
        view.onFailure = onFailure
        view.configure(player: player, edit: edit, track: track)
    }
    static func dismantleUIView(_ view: EffectVideoView, coordinator: ()) { view.stop() }
}

/// A Power Shot replay: the same decoded-frame pipeline, drawing a shot trail instead.
struct ShotVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let style: ShotTrailStyle
    var intensity = 1.0
    let track: BallEffectTrack
    var camera = ShotCameraSettings()
    var flight: ShotFlight?
    var clock = ShotReplayClock()
    var onFailure: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> EffectVideoView { EffectVideoView() }
    func updateUIView(_ view: EffectVideoView, context: Context) {
        view.onFailure = onFailure
        view.configure(player: player, shot: style, intensity: intensity, track: track,
                       camera: camera, flight: flight, clock: clock)
    }
    static func dismantleUIView(_ view: EffectVideoView, coordinator: ()) { view.stop() }
}

struct MetalStillSurface: UIViewRepresentable {
    let image: CGImage
    let edit: SessionEditState
    let track: BallEffectTrack
    let time: Double
    var onFailure: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> EffectVideoView { EffectVideoView() }
    func updateUIView(_ view: EffectVideoView, context: Context) {
        view.onFailure = onFailure
        view.configure(image: image, edit: edit, track: track, time: time)
    }
    static func dismantleUIView(_ view: EffectVideoView, coordinator: ()) { view.stop() }
}

final class EffectVideoView: MTKView {
    private var engine: MetalEffectEngine?
    private var textureCache: CVMetalTextureCache?
    private weak var player: AVPlayer?
    private var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var displayTarget: DisplayTarget?
    private var pixels: CVPixelBuffer?
    private var stillImage: CGImage?
    private var stillTexture: MTLTexture?
    private var frameTime = 0.0
    private var edit = SessionEditState()
    /// Set for a Power Shot replay; juggling replays build their frame from `edit`.
    private var shot: (style: ShotTrailStyle, intensity: Double)?
    private var shotCamera = ShotCameraSettings()
    private var shotFlight: ShotFlight?
    private var shotClock = ShotReplayClock()
    private var track = BallEffectTrack(frames: [])
    private var dirty = true
    private var previousSize = CGSize.zero
    private let inFlight = DispatchSemaphore(value: 2)
    private let materialPool = BallMaterialTexturePool()
    // Visible to lifecycle regressions; these count owned canvases/textures.
    var materialAllocationCount: Int { materialPool.allocationCount }
    var retainedMaterialSlotCount: Int { materialPool.retainedSlotCount }
    private var reportedError = false
    var onFailure: (String) -> Void = { _ in }
    #if DEBUG
    /// --preview-benchmark <seconds>: play from the start once the ball skin is
    /// active and record per-frame preview cost. Debug harness only.
    private var benchmark: PreviewBenchmark?
    #endif

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .black
        contentScaleFactor = min(2, traitCollection.displayScale)
        do {
            let engine = try MetalEffectEngine()
            self.engine = engine
            device = engine.device
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, engine.device, nil, &textureCache) == kCVReturnSuccess else {
                throw MetalEffectEngine.Failure.unavailable("Couldn’t prepare the video texture cache.")
            }
        } catch { report(error) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private final class DisplayTarget: NSObject {
        weak var view: EffectVideoView?
        @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            dirty = true
            if displayLink == nil {
                let target = DisplayTarget(); target.view = self
                let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayTarget = target; displayLink = link
            }
        } else {
            displayLink?.invalidate(); displayLink = nil; displayTarget = nil
        }
    }

    func configure(player: AVPlayer, edit: SessionEditState, track: BallEffectTrack) {
        if self.edit != edit || self.track.surfaceMotion?.entries.count != track.surfaceMotion?.entries.count { dirty = true; setNeedsDisplay() }
        if edit.ballSkin == .original { materialPool.removeAll() }
        self.edit = edit; self.track = track; self.player = player
        #if DEBUG
        if benchmark == nil, edit.ballSkin != .original, track.surfaceMotion != nil,
           let seconds = SessionDesignReview.argument("--preview-benchmark").flatMap(Double.init) {
            benchmark = PreviewBenchmark(seconds: seconds, skin: edit.ballSkin.rawValue)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async { player.play() }
            }
        }
        #endif
        guard item !== player.currentItem else { return }
        if let item, let output { item.remove(output) }
        item = player.currentItem
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        output.suppressesPlayerRendering = true
        item?.add(output)
        self.output = output; pixels = nil; dirty = true
    }

    func configure(player: AVPlayer, shot style: ShotTrailStyle, intensity: Double, track: BallEffectTrack,
                   camera: ShotCameraSettings = .init(), flight: ShotFlight? = nil, clock: ShotReplayClock = .init()) {
        if shot?.style != style || shot?.intensity != intensity || self.track.samples.count != track.samples.count ||
            shotCamera != camera || shotClock != clock || shotFlight != flight {
            dirty = true; setNeedsDisplay()
        }
        shot = (style, intensity)
        shotCamera = camera; shotFlight = flight; shotClock = clock
        configure(player: player, edit: SessionEditState(style: .none, intensity: 0), track: track)
    }

    func configure(image: CGImage, edit: SessionEditState, track: BallEffectTrack, time: Double) {
        if self.edit != edit || frameTime != time { dirty = true; setNeedsDisplay() }
        if edit.ballSkin == .original { materialPool.removeAll() }
        self.edit = edit; self.track = track; frameTime = time
        if stillImage !== image, let engine {
            stillImage = image
            do {
                stillTexture = try MTKTextureLoader(device: engine.device).newTexture(cgImage: image,
                    options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
                dirty = true
            } catch { report(error) }
        }
    }

    func stop() {
        displayLink?.invalidate(); displayLink = nil; displayTarget = nil
        if let item, let output { item.remove(output) }
        output = nil; item = nil; pixels = nil; player = nil
        stillImage = nil; stillTexture = nil
        track = BallEffectTrack(frames: [])
        materialPool.removeAll()
        engine?.releaseCameraTargets()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    private func tick(_ link: CADisplayLink) {
        guard window != nil, engine != nil else { return }
        if let output, let player {
            let requested = player.rate == 0 ? player.currentTime() : output.itemTime(forHostTime: link.targetTimestamp)
            if output.hasNewPixelBuffer(forItemTime: requested) {
                var displayed = CMTime.invalid
                if let frame = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayed) {
                    pixels = frame
                    let stamp = displayed.isValid ? displayed : requested
                    let decodedTime = max(0, CMTimeGetSeconds(stamp))
                    frameTime = shot == nil ? decodedTime : shotClock.sourceTime(for: decodedTime)
                    dirty = true
                }
            }
        }
        if drawableSize != previousSize { dirty = true }
        if dirty { setNeedsDisplay() }
    }

    // MTKView releases its presented drawable after this drawing callback.
    // Fetching currentDrawable directly in CADisplayLink can reuse a stale
    // drawable, especially when editing a paused frame.
    override func draw(_ rect: CGRect) {
        #if DEBUG
        let drawStart = ProcessInfo.processInfo.systemUptime
        if dirty, engine != nil, inFlight.wait(timeout: .now()) == .success { inFlight.signal() }
        else if dirty { benchmark?.busySkip() }
        #endif
        guard let engine, dirty, drawableSize.width > 0, drawableSize.height > 0,
              inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        do {
            var videoReference: CVMetalTexture?
            let source: MTLTexture
            if let pixels, let textureCache {
                guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixels, nil,
                    .bgra8Unorm, CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &videoReference) == kCVReturnSuccess,
                      let videoReference, let videoTexture = CVMetalTextureGetTexture(videoReference) else {
                    throw MetalEffectEngine.Failure.unavailable("Couldn’t read this video frame.")
                }
                source = videoTexture
            } else if let stillTexture { source = stillTexture }
            else { return }
            guard let drawable = currentDrawable, let command = engine.resources.queue.makeCommandBuffer() else { return }
            let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let sourceSize = CGSize(width: source.width, height: source.height)
            let frame = shot.map { EffectFrame.shot(size: size, sourceSize: sourceSize, style: $0.style,
                                                     intensity: $0.intensity, track: track, time: frameTime) }
                ?? EffectFrame.video(size: size, sourceSize: sourceSize, edit: edit, track: track, time: frameTime)
            #if DEBUG
            let materialStart = ProcessInfo.processInfo.systemUptime
            #endif
            let material = try materialTexture(engine: engine, size: size, sourceSize: sourceSize)
            #if DEBUG
            let materialMS = (ProcessInfo.processInfo.systemUptime - materialStart) * 1000
            #endif
            let camera = shot.map { _ in ShotCameraFrame.make(settings: shotCamera, track: track,
                                                              flight: shotFlight, size: size, time: frameTime) }
            try engine.encode(frame, into: drawable.texture, source: source, material: material?.texture,
                              camera: camera, command: command)
            command.present(drawable)
            let retainedPixels = pixels
            let semaphore = inFlight
            command.addCompletedHandler { [weak self] completed in
                withExtendedLifetime((videoReference, retainedPixels, material)) {}
                material?.release()
                semaphore.signal()
                if let error = completed.error { Task { @MainActor [weak self] in self?.report(error) } }
            }
            command.commit(); submitted = true
            previousSize = drawableSize; dirty = false
            #if DEBUG
            benchmark?.record(frameTime: frameTime, materialMS: materialMS,
                              drawMS: (ProcessInfo.processInfo.systemUptime - drawStart) * 1000)
            #endif
        } catch { report(error) }
    }

    private func materialTexture(engine: MetalEffectEngine, size: CGSize, sourceSize: CGSize) throws -> BallMaterialTexturePool.Lease? {
        guard edit.ballSkin != .original else { return nil }
        let width = Int(size.width), height = Int(size.height)
        guard let lease = try materialPool.acquire(device: engine.device, width: width, height: height) else {
            throw MetalEffectEngine.Failure.unavailable("The ball material buffers are still in use.")
        }
        let context = lease.context
        let sample = track.replacementGuide(at: frameTime)
        let mask = track.mask(at: frameTime)
        let fitted = sample.flatMap { sample -> BallReplacementFootprint? in
            if let pixels { return BallReplacementFootprint.fit(pixels: pixels, sample: sample, measureTexture: true) }
            if let stillImage { return BallReplacementFootprint.fit(image: stillImage, sample: sample, measureTexture: true) }
            return nil
        }
        // Motion smear comes from the shared track, so replay and export agree.
        let smear = track.smear(at: frameTime, size: sourceSize)
        let matte = mask.map { BallReplacementCoverage(mask: $0, fitted: fitted, size: sourceSize, smear: smear) }
        let footprint = track.usesBallMasks ? matte?.footprint : fitted
        let coverage: ((Double, Double) -> Double)? = matte.map { m in
            { x, y in m.coverage(x: x, y: y) }
        }
        let replacement = BallMaterialRenderer.replacement(footprint: footprint, skin: edit.ballSkin,
            time: frameTime, coverage: coverage, coverageBounds: matte?.bounds,
            orientation: track.surfaceMotion?.renderOrientation(at: frameTime), smear: smear,
            light: track.surfaceMotion?.light(at: frameTime))
        // No supported silhouette: retain the source instead of inventing a ball.
        BallMaterialRenderer.draw(in: context, size: size, sourceSize: sourceSize, skin: edit.ballSkin,
            sample: replacement == nil ? nil : sample, time: frameTime, replacement: replacement)
        lease.upload()
        return lease
    }

    private func report(_ error: Error) {
        guard !reportedError else { return }
        reportedError = true
        let message = error.localizedDescription
        NSLog("KickLab video effects: %@", message)
        DispatchQueue.main.async { [weak self] in self?.onFailure(message) }
    }
}

#if DEBUG
/// Per-frame preview cost on the device. Written once to Documents/preview-benchmark.json.
final class PreviewBenchmark {
    private let seconds: Double, skin: String
    private var rows: [[Double]] = [], skips = 0, started: Double?, written = false
    init(seconds: Double, skin: String) { self.seconds = seconds; self.skin = skin }
    func busySkip() { if started != nil { skips += 1 } }
    func record(frameTime: Double, materialMS: Double, drawMS: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if started == nil { started = now }
        guard !written, let started else { return }
        rows.append([now - started, frameTime, materialMS, drawMS])
        guard now - started >= seconds else { return }
        written = true
        let report: [String: Any] = ["skin": skin, "seconds": now - started, "busy_skips": skips,
                                     "rows": rows, "columns": ["wall_s", "video_s", "material_ms", "draw_ms"]]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("preview-benchmark.json"))
        }
    }
}
#endif
