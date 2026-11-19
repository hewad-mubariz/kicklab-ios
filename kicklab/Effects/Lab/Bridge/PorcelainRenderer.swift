// Copied from the Effects Lab (EffectLab/PorcelainRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo

/// Resource ownership is shared with the frozen renderer; the new pipeline and
/// draw call are separate, so the accepted gold material stays byte-identical.
nonisolated final class PorcelainGPU {
    let resources:GoldGPU
    let pipeline:MTLRenderPipelineState
    let artwork:MTLTexture
    var device:MTLDevice{resources.device}
    init(device:MTLDevice?=MTLCreateSystemDefaultDevice(),libraryURL:URL?=nil,directory:URL?=nil)throws {
        let resources=try GoldGPU(device:device,libraryURL:libraryURL,directory:directory)
        self.resources=resources
        guard let artworkURL=directory?.appendingPathComponent("porcelain-artwork.png") ?? Bundle.main.url(forResource:"porcelain-artwork",withExtension:"png") else {throw GoldGPU.failure("Missing porcelain artwork")}
        artwork=try MTKTextureLoader(device:resources.device).newTexture(URL:artworkURL,options:[.SRGB:false,.generateMipmaps:true,.origin:MTKTextureLoader.Origin.topLeft])
        let library=try libraryURL.map{try resources.device.makeLibrary(URL:$0)} ?? resources.device.makeDefaultLibrary()
        guard let library else {throw GoldGPU.failure("Skin shaders unavailable")}
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"porcelainVertex")
        descriptor.fragmentFunction=library.makeFunction(name:"porcelainFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try resources.device.makeRenderPipelineState(descriptor:descriptor)
    }
    func makeTexture(width:Int,height:Int)->MTLTexture{resources.makeTexture(width:width,height:height)}
    func texture(_ pixels:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture){try resources.texture(pixels)}
    func bounds(_ frame:GoldUniforms,width:Int,height:Int)->MTLScissorRect{resources.bounds(frame,width:width,height:height)}
    @discardableResult func render(frame:GoldUniforms,source:MTLTexture?,target:MTLTexture,drawable:CAMetalDrawable?=nil,wait:Bool=true)throws->MTLCommandBuffer {
        guard let command=resources.queue.makeCommandBuffer() else{throw GoldGPU.failure("Skin command allocation")}
        if let source {let b=command.makeBlitCommandEncoder()!;b.copy(from:source,to:target);b.endEncoding()}
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=source==nil ? .dontCare:.load;pass.colorAttachments[0].storeAction = .store
        guard let e=command.makeRenderCommandEncoder(descriptor:pass) else{throw GoldGPU.failure("Skin render encoder")}
        var uniforms=frame
        e.setRenderPipelineState(pipeline);e.setFragmentBytes(&uniforms,length:MemoryLayout<GoldUniforms>.stride,index:0)
        e.setFragmentTexture(source ?? resources.dummy,index:0);e.setFragmentTexture(resources.environment,index:1)
        e.setFragmentTexture(artwork,index:2)
        if source != nil {e.setScissorRect(bounds(frame,width:target.width,height:target.height))}
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding()
        if let drawable{command.present(drawable)}
        command.commit()
        if wait{command.waitUntilCompleted();if let error=command.error{throw error}}
        return command
    }
}
