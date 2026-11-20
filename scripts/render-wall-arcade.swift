// swift scripts/render-wall-arcade.swift <scene.metallib> <output-folder>
// Renders the shipping stationary Metal backdrop for visual/performance review.
import AppKit
import Metal

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
let queue = device.makeCommandQueue()!
let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = library.makeFunction(name: "wallArcadeSceneVertex")
descriptor.fragmentFunction = library.makeFunction(name: "wallArcadeSceneFragment")
descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, theme) in [("ruins", Float(0)), ("city", Float(1))] {
    let w = 1600, h = 900
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    td.storageMode = .shared; td.usage = [.renderTarget, .shaderRead]
    let texture = device.makeTexture(descriptor: td)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    var uniforms = SIMD4<Float>(Float(w), Float(h), theme, 0)
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&uniforms, length: 16, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    var data = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&data, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let provider = CGDataProvider(data: Data(data) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    print("\(name): \((command.gpuEndTime-command.gpuStartTime)*1000) ms GPU on this Mac; on-demand, not a phone benchmark")
}
