#if DEBUG && BALL_DETECTION_DEBUG
import MetalKit
import SwiftUI
import OSLog

/// A bounded fire surface, driven by the game's paused clock. Each meteor
/// resolves at up to 384 pixels, so projector resolution cannot multiply the
/// procedural fire cost. The three display buffers use under 2 MiB per rock.
struct WallMeteorSurface: UIViewRepresentable {
    let seed: Int
    let time: Double
    func makeUIView(context: Context) -> WallMeteorMetalView { WallMeteorMetalView() }
    func updateUIView(_ view: WallMeteorMetalView, context: Context) { view.update(seed: seed, time: time) }
}

final class WallMeteorMetalView: MTKView {
    private final class Resources {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary() else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "wallMeteorVertex")
            d.fragmentFunction = library.makeFunction(name: "wallMeteorFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline: MTLRenderPipelineState
            do { pipeline = try device.makeRenderPipelineState(descriptor: d) }
            catch {
                Logger().error("Meteor fire pipeline: \(error.localizedDescription)")
                return nil
            }
            self.device = device; self.queue = queue; self.pipeline = pipeline
        }
    }
    private static let resources = Resources()
    private var state = SIMD2<Float>(-1, -1)
    private let inFlight = DispatchSemaphore(value: 2)
    init() {
        super.init(frame: .zero, device: Self.resources?.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false; backgroundColor = .clear
        isPaused = true; enableSetNeedsDisplay = true; autoResizeDrawable = false
        isUserInteractionEnabled = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(seed: Int, time: Double) {
        let next = SIMD2(Float(seed), Float(time))
        guard next != state else { return }
        state = next; setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(2, 384 / max(bounds.width, bounds.height))
        let next = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != next { drawableSize = next; setNeedsDisplay() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsDisplay() }
    }
    override func draw(_ rect: CGRect) {
        guard let resources = Self.resources, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = resources.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal(); return
        }
        var u = SIMD4<Float>(Float(drawable.texture.width), Float(drawable.texture.height), state.x, state.y)
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentBytes(&u, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let semaphore = inFlight
        command.addCompletedHandler { buffer in
            if let error = buffer.error { Logger().error("Meteor fire: \(error.localizedDescription)") }
            semaphore.signal()
        }
        command.present(drawable); command.commit()
    }
}
#endif
