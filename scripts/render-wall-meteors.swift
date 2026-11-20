// swift scripts/render-wall-meteors.swift <WallArcadeShaders.metallib> <output-folder>
// Exercises the actual bounded meteor pipeline, with alpha and timing checks.
import AppKit
import Metal

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
let queue = device.makeCommandQueue()!
let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = library.makeFunction(name: "wallMeteorVertex")
descriptor.fragmentFunction = library.makeFunction(name: "wallMeteorFragment")
descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
let folder = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var timings: [Double] = [], previous: [UInt8]?
for i in 0..<30 {
    let w = 372, h = 384
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    td.storageMode = .shared; td.usage = [.renderTarget, .shaderRead]
    let texture = device.makeTexture(descriptor: td)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    var u = SIMD4<Float>(Float(w), Float(h), 1, 3 + Float(i) / 30)
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&u, length: 16, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    timings.append((command.gpuEndTime - command.gpuStartTime) * 1000)
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    assert(pixels[3] == 0 && pixels[(w * h - 1) * 4 + 3] == 0, "Fire reaches the bounding corners")
    let rock = (Int(Double(h) * 0.78) * w + w / 2) * 4
    assert(pixels[rock + 3] > 240, "Rock centre must remain solid")
    assert(pixels[rock + 2] > 80, "Rock face too dark for a projector")
    if let previous { assert(previous != pixels, "Fire did not animate") }
    previous = pixels
    if [0, 10, 20].contains(i) {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("meteor-\(i).png"))
    }
}
timings.sort()
print("30 GPU frames passed: solid bright core, transparent bounds, evolving fire.")
print("Mac GPU median: \(timings[15]) ms; max: \(timings.last!) ms. Not a phone thermal benchmark.")
