import SwiftUI
import MetalKit
import OSLog

/// The clock belongs to the video/HUD. A paused video never animates its effects.
struct MetalEffectSurface: UIViewRepresentable {
    var frame: (CGSize) -> EffectFrame?

    func makeUIView(context: Context) -> MetalEffectView { MetalEffectView() }
    func updateUIView(_ view: MetalEffectView, context: Context) {
        view.updateFrame(frame)
    }
}

final class MetalEffectView: MTKView {
    var makeFrame: ((CGSize) -> EffectFrame?)?
    private let engine: MetalEffectEngine?
    private let inFlight = DispatchSemaphore(value: 2)
    private var reportedError = false
    private var requestedFrame: EffectFrame?
    private var hasRequestedFrame = false

    func updateFrame(_ builder: @escaping (CGSize) -> EffectFrame?) {
        makeFrame = builder
        let next = builder(drawableSize)
        // Static option thumbnails must not rerender at the video frame rate.
        if !hasRequestedFrame || next != requestedFrame { setNeedsDisplay() }
        requestedFrame = next
        hasRequestedFrame = true
    }

    init() {
        engine = try? MetalEffectEngine()
        super.init(frame: .zero, device: engine?.device)
        isOpaque = false; backgroundColor = .clear
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        isPaused = true; enableSetNeedsDisplay = true
        isUserInteractionEnabled = false
        // Two physical pixels per point keeps preview detail without a full 3x
        // screen resolve. Exports always render at their requested resolution.
        contentScaleFactor = 2
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        contentScaleFactor = min(2, window?.screen.scale ?? 2)
    }

    override func draw(_ rect: CGRect) {
        guard let engine, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let command = engine.resources.queue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        do {
            if let frame = makeFrame?(CGSize(width: drawable.texture.width, height: drawable.texture.height)),
               !frame.region.isNull, frame.region.width > 0, frame.region.height > 0 {
                try engine.encode(frame, into: drawable.texture, command: command)
            } else {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.texture
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = clearColor
                command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            let semaphore = inFlight
            command.addCompletedHandler { buffer in
                if let error = buffer.error { Logger().error("Effect GPU command failed: \(error.localizedDescription)") }
                semaphore.signal()
            }
            command.present(drawable); command.commit()
        } catch {
            inFlight.signal()
            if !reportedError { Logger().error("Effect render failed: \(error.localizedDescription)"); reportedError = true }
        }
    }
}
