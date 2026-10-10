import CoreVideo
import Foundation
import MetalKit
import simd

/// Shared by the in-app preview and the real-video study. The procedural
/// stadium is rendered in world space before compositing the foreground.
nonisolated final class StadiumPreviewRenderer {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { switch self { case .unavailable(let message): return message } }
    }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    private let panorama: MTLTexture
    private let boards: MTLTexture
    private let turf: MTLTexture
    private let arenaSigns: MTLTexture
    private let arenaConcrete: MTLTexture
    private let urbanSigns: MTLTexture
    private let forestTrees: MTLTexture
    private let forestSigns: MTLTexture
    private let seasonalTrees: MTLTexture
    private let snowMountains: MTLTexture
    private var cache: CVMetalTextureCache?
    struct Uniforms {
        var eye, right, up, forward, camera, source, contact: SIMD4<Float>
        var sourceRight, sourceUp, sourceForward, layout, crop: SIMD4<Float>
    }
    init(library: String? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable("The stadium preview needs Metal on this device.")
        }
        self.device = device; self.queue = queue
        let loader=MTKTextureLoader(device:device)
        func asset(_ name:String) throws -> MTLTexture {
            #if os(macOS)
            if library != nil {
                let url=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("kicklab/Assets.xcassets/\(name).imageset/\(name).png")
                return try loader.newTexture(URL:url,options:[.SRGB:true,.generateMipmaps:true])
            }
            #endif
            return try loader.newTexture(name:name,scaleFactor:1,bundle:.main,options:[.SRGB:true,.generateMipmaps:true])
        }
        panorama=try asset("stadium-panorama-v2");boards=try StadiumSignage.make(device:device);turf=try asset("stadium-turf-v2")
        arenaSigns=try ArenaSignage.make(device:device)
        urbanSigns=try UrbanSignage.make(device:device)
        forestTrees=try asset("forest-trees-v2")
        forestSigns=try ForestSignage.make(device:device)
        seasonalTrees=try asset("seasonal-trees-v1")
        snowMountains=try asset("snow-mountains-v1")
        arenaConcrete=try asset("arena-concrete-v1")
        let lib = try library.map { try device.makeLibrary(URL: URL(fileURLWithPath: $0)) } ?? device.makeDefaultLibrary()
        guard let function = lib?.makeFunction(name: "foregroundStudy") else {
            throw Failure.unavailable("The stadium renderer could not be loaded.")
        }
        pipeline = try device.makeComputePipelineState(function: function)
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw ForegroundMaskProcessor.Failure.allocation
        }
    }
    func render(source: CVPixelBuffer, mask: CVPixelBuffer, output: CVPixelBuffer, camera: SceneCameraRig, time: Double, scene: Bool,
                packed:Bool=false,sourceRect:CGRect=CGRect(x:0,y:0,width:1,height:1),environment:PreviewEnvironment = .classicStadium,refined:Bool=false,separateAlpha:Bool=false) throws {
        var refs: [CVMetalTexture] = []
        func texture(_ buffer: CVPixelBuffer) throws -> MTLTexture {
            var ref: CVMetalTexture?
            let format:MTLPixelFormat=CVPixelBufferGetPixelFormatType(buffer)==kCVPixelFormatType_OneComponent8 ? .r8Unorm:.bgra8Unorm
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache!, buffer, nil, format,
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &ref) == kCVReturnSuccess,
                  let ref, let texture = CVMetalTextureGetTexture(ref) else { throw ForegroundMaskProcessor.Failure.allocation }
            refs.append(ref); return texture
        }
        let a = try texture(source), b = try texture(mask), c = try texture(output)
        guard let command=queue.makeCommandBuffer() else {throw ForegroundMaskProcessor.Failure.allocation}
        try encode(source:a,mask:b,target:c,camera:camera,time:time,scene:scene,packed:packed,sourceRect:sourceRect,environment:environment,refined:refined,separateAlpha:separateAlpha,command:command)
        command.commit();command.waitUntilCompleted()
        if let error=command.error {throw error}
        withExtendedLifetime(refs) {}
    }

    func encode(source a:MTLTexture,mask b:MTLTexture,target c:MTLTexture,camera:SceneCameraRig,
                time:Double,scene:Bool=true,packed:Bool=false,sourceRect:CGRect=CGRect(x:0,y:0,width:1,height:1),
                environment:PreviewEnvironment = .classicStadium,refined:Bool=false,separateAlpha:Bool=false,command:MTLCommandBuffer) throws {
        let pose = camera.pose(at: time), basis=camera.sourceBasis
        func v(_ p: SIMD3<Float>) -> SIMD4<Float> { SIMD4(p.x,p.y,p.z,0) }
        var u = Uniforms(eye:v(pose.eye),right:v(pose.right),up:v(pose.up),forward:v(pose.forward),
            camera:SIMD4(camera.aspect,camera.viewTanHalfFOV,camera.horizon,camera.subjectDistance),
            source:SIMD4(camera.eyeHeight,camera.subjectZ,scene ? 1 : 0,Float(time)),
            contact:SIMD4(camera.support.x,camera.support.z,camera.supportWidth,camera.contact?.confidence ?? 0),
            sourceRight:v(basis.right),sourceUp:v(basis.up),sourceForward:v(basis.forward),
            layout:SIMD4(packed ? (separateAlpha ? 3:refined ? 2:1):0,camera.tanHalfFOV,camera.distance,environment.shaderIndex),
            crop:SIMD4(Float(sourceRect.minX),Float(sourceRect.minY),Float(sourceRect.width),Float(sourceRect.height)))
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw ForegroundMaskProcessor.Failure.allocation
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
        encoder.setTexture(a,index:0);encoder.setTexture(b,index:1);encoder.setTexture(c,index:2)
        encoder.setTexture(panorama,index:3);encoder.setTexture(boards,index:4);encoder.setTexture(turf,index:5)
        encoder.setTexture(arenaSigns,index:6)
        encoder.setTexture(arenaConcrete,index:7)
        encoder.setTexture(urbanSigns,index:8)
        encoder.setTexture(forestTrees,index:9)
        encoder.setTexture(forestSigns,index:10)
        encoder.setTexture(seasonalTrees,index:11)
        encoder.setTexture(snowMountains,index:12)
        encoder.dispatchThreads(MTLSize(width:c.width,height:c.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
        encoder.endEncoding()
    }
}
