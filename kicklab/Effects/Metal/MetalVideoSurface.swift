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
    private var track = BallEffectTrack(frames: [])
    private var dirty = true
    private var previousSize = CGSize.zero
    private let inFlight = DispatchSemaphore(value: 2)
    private var reportedError = false
    var onFailure: (String) -> Void = { _ in }

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
        if self.edit != edit { dirty = true; setNeedsDisplay() }
        self.edit = edit; self.track = track; self.player = player
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

    func configure(image: CGImage, edit: SessionEditState, track: BallEffectTrack, time: Double) {
        if self.edit != edit || frameTime != time { dirty = true; setNeedsDisplay() }
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
                    frameTime = max(0, CMTimeGetSeconds(stamp))
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
            let frame = EffectFrame.video(size: size, sourceSize: sourceSize, edit: edit, track: track, time: frameTime)
            let material = try materialTexture(engine: engine, size: size, sourceSize: sourceSize)
            try engine.encode(frame, into: drawable.texture, source: source, material: material, command: command)
            command.present(drawable)
            let retainedPixels = pixels
            let semaphore = inFlight
            command.addCompletedHandler { [weak self] completed in
                withExtendedLifetime((videoReference, retainedPixels, material)) {}
                semaphore.signal()
                if let error = completed.error { Task { @MainActor [weak self] in self?.report(error) } }
            }
            command.commit(); submitted = true
            previousSize = drawableSize; dirty = false
        } catch { report(error) }
    }

    private func materialTexture(engine: MetalEffectEngine, size: CGSize, sourceSize: CGSize) throws -> MTLTexture? {
        guard edit.ballSkin != .original else { return nil }
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { throw MetalEffectEngine.Failure.unavailable("Couldn’t draw the ball material.") }
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        let sample = track.replacementGuide(at: frameTime)
        let mask = track.mask(at: frameTime)
        let footprint: BallReplacementFootprint? = track.usesBallMasks ? mask?.footprint(in: sourceSize) : sample.flatMap { sample in
            if let pixels { return BallReplacementFootprint.fit(pixels: pixels, sample: sample) }
            if let stillImage { return BallReplacementFootprint.fit(image: stillImage, sample: sample) }
            return nil
        }
        let coverage: ((Double, Double) -> Double)? = mask.map { m in
            { x, y in m.coverage(x: x/sourceSize.width, y: y/sourceSize.height) }
        }
        let replacement = BallMaterialRenderer.replacement(footprint: footprint, skin: edit.ballSkin, time: frameTime, coverage: coverage)
        // No supported silhouette: retain the source instead of inventing a ball.
        BallMaterialRenderer.draw(in: context, size: size, sourceSize: sourceSize, skin: edit.ballSkin,
            sample: replacement == nil ? nil : sample, time: frameTime, replacement: replacement)
        let texture = try engine.texture(width: width, height: height, storage: .shared)
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        return texture
    }

    private func report(_ error: Error) {
        guard !reportedError else { return }
        reportedError = true
        let message = error.localizedDescription
        NSLog("KickLab video effects: %@", message)
        DispatchQueue.main.async { [weak self] in self?.onFailure(message) }
    }
}
