#if DEBUG && BALL_DETECTION_DEBUG
import MetalKit
import SwiftUI
import OSLog

/// A stationary Metal scene: draw on creation, resize or theme change only.
/// The camera detector and the small moving effects retain the frame budget.
struct WallArcadeBackdrop: UIViewRepresentable {
    enum Theme: Float { case ruins = 0, city = 1 }
    var theme: Theme

    func makeUIView(context: Context) -> WallArcadeSceneView {
        WallArcadeSceneView(theme: theme.rawValue)
    }
    func updateUIView(_ view: WallArcadeSceneView, context: Context) {
        view.setTheme(theme.rawValue)
    }
}

final class WallArcadeSceneView: MTKView {
    private final class Resources {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary() else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "wallArcadeSceneVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "wallArcadeSceneFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            self.device = device; self.queue = queue; self.pipeline = pipeline
        }
    }
    private static let resources = Resources()
    private var theme: Float
    private let inFlight = DispatchSemaphore(value: 2)

    init(theme: Float) {
        self.theme = theme
        super.init(frame: .zero, device: Self.resources?.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        isOpaque = true; backgroundColor = .black
        isPaused = true; enableSetNeedsDisplay = true
        autoResizeDrawable = false
        isUserInteractionEnabled = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTheme(_ next: Float) {
        guard next != theme else { return }
        theme = next; setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(2, 1536 / bounds.width)
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
        var uniforms = SIMD4<Float>(Float(drawable.texture.width), Float(drawable.texture.height), theme, 0)
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let semaphore = inFlight
        command.addCompletedHandler { buffer in
            if let error = buffer.error { Logger().error("Arcade scenery: \(error.localizedDescription)") }
            semaphore.signal()
        }
        command.present(drawable); command.commit()
    }
}
#endif
