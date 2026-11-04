import CoreGraphics
import Foundation
import Metal
import simd

// A serial benchmark-only adapter. Includes command completion and CPU readback in its cost.
enum GPUProbe {
    static var enabled = false
    static let skins: [BallSkin] = [.classic,.stealth,.matrix,.gold,.arctic,.crimson,.galaxy,.chrome,.graffiti,.aurora,.metal,.lava,.pearl,.volt]
    static var renderer: GPUSphere!
}
final class GPUSphere {
    struct Params { var pose: SIMD4<Float>; var options: SIMD4<UInt32> }
    let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState
    private var maps: [BallSkin: (MTLBuffer, MTLBuffer)] = [:]
    private var outputs: [Int: MTLBuffer] = [:]
    init(shader: String) throws {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: shader, options: options)
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "sphere")!)
    }
    func image(skin: BallSkin, time: Double, size: Int, orientation: simd_quatf?, rgba: [UInt8], normals: [UInt8]) -> CGImage? {
        if maps[skin] == nil {
            maps[skin] = (rgba.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! },
                          normals.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! })
        }
        if outputs[size] == nil { outputs[size] = device.makeBuffer(length: size*size*4, options: .storageModeShared)! }
        let output = outputs[size]!, map = maps[skin]!
        let t = Float(Double(Int64((max(0,min(time,1e7))*60).rounded()))/60)
        // CPU fallback samples Rx(-pitch) * Ry(-yaw) * view; the material pose is its inverse.
        let pose = orientation ?? (simd_quatf(angle: t*1.1+0.35, axis: SIMD3(0,1,0))
            * simd_quatf(angle: t*0.29+0.18, axis: SIMD3(1,0,0)))
        var params = Params(pose: pose.vector, options: SIMD4(UInt32(size),UInt32(GPUProbe.skins.firstIndex(of:skin)!),0,0))
        let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(map.0,offset:0,index:0);encoder.setBuffer(map.1,offset:0,index:1);encoder.setBuffer(output,offset:0,index:2)
        encoder.setBytes(&params,length:MemoryLayout<Params>.stride,index:3)
        encoder.dispatchThreads(MTLSize(width:size,height:size,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        precondition(command.error == nil, "GPU command failed: \(String(describing: command.error))")
        let provider = CGDataProvider(data:Data(bytes:output.contents(),count:size*size*4) as CFData)!
        return CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:size*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}
