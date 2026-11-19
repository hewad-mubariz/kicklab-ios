// Copied from the Effects Lab (EffectLab/DragonhideRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo

/// Separate geometry pipeline; shared lighting/allocation code remains unchanged.
nonisolated final class DragonhideGPU {
    let resources:GoldGPU
    let scalesPipeline:MTLRenderPipelineState,compositePipeline:MTLRenderPipelineState
    let depthState:MTLDepthStencilState
    let vertices:MTLBuffer,indices:MTLBuffer,indexCount:Int,scaleCount:Int
    private var msaa:MTLTexture?,depth:MTLTexture?,resolved:MTLTexture?
    private var needsPriming=true
    var device:MTLDevice{resources.device}
    init(device:MTLDevice?=MTLCreateSystemDefaultDevice(),libraryURL:URL?=nil,directory:URL?=nil)throws {
        let resources=try GoldGPU(device:device,libraryURL:libraryURL,directory:directory)
        self.resources=resources
        let library=try libraryURL.map{try resources.device.makeLibrary(URL:$0)} ?? resources.device.makeDefaultLibrary()
        guard let library,resources.device.supportsTextureSampleCount(4) else {throw GoldGPU.failure("Dragonhide requires Metal 4x MSAA")}
        let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:"dragonhideScaleVertex");d.fragmentFunction=library.makeFunction(name:"dragonhideScaleFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm;d.depthAttachmentPixelFormat = .depth32Float;d.rasterSampleCount=4
        scalesPipeline=try resources.device.makeRenderPipelineState(descriptor:d)
        let c=MTLRenderPipelineDescriptor();c.vertexFunction=library.makeFunction(name:"dragonhideCompositeVertex");c.fragmentFunction=library.makeFunction(name:"dragonhideCompositeFragment");c.colorAttachments[0].pixelFormat = .bgra8Unorm
        compositePipeline=try resources.device.makeRenderPipelineState(descriptor:c)
        let ds=MTLDepthStencilDescriptor();ds.depthCompareFunction = .less;ds.isDepthWriteEnabled=true;depthState=resources.device.makeDepthStencilState(descriptor:ds)!
        let mesh=DragonhideMesh.make();scaleCount=mesh.2;indexCount=mesh.1.count
        guard mesh.0.allSatisfy({$0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite}),mesh.1.allSatisfy({Int($0)<mesh.0.count}) else {throw GoldGPU.failure("Invalid scale geometry")}
        vertices=mesh.0.withUnsafeBytes{resources.device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
        indices=mesh.1.withUnsafeBytes{resources.device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
        print("Dragonhide geometry: \(scaleCount) scales, \(mesh.0.count) vertices, \(indexCount/3) triangles")
    }
    func makeTexture(width:Int,height:Int)->MTLTexture{resources.makeTexture(width:width,height:height)}
    func texture(_ pixels:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture){try resources.texture(pixels)}
    func bounds(_ frame:GoldUniforms,width:Int,height:Int)->MTLScissorRect{resources.bounds(frame,width:width,height:height)}
    private func prepare(_ width:Int,_ height:Int)throws {
        if resolved?.width==width && resolved?.height==height{return}
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false);d.storageMode = .private;d.usage=[.renderTarget,.shaderRead]
        resolved=device.makeTexture(descriptor:d)
        d.textureType = .type2DMultisample;d.sampleCount=4;d.usage = .renderTarget;msaa=device.makeTexture(descriptor:d)
        d.pixelFormat = .depth32Float;depth=device.makeTexture(descriptor:d)
        guard resolved != nil,msaa != nil,depth != nil else{throw GoldGPU.failure("Dragonhide render target allocation")}
        needsPriming=true
    }
    @discardableResult func render(frame:GoldUniforms,source:MTLTexture?,target:MTLTexture,drawable:CAMetalDrawable?=nil,wait:Bool=true)throws->MTLCommandBuffer {
        try prepare(target.width,target.height)
        // The cold MSAA resolve can differ at a handful of overlap/silhouette pixels.
        // Prime new targets before displaying or exporting their first frame.
        if needsPriming {
            needsPriming=false
            try render(frame:frame,source:source,target:target,wait:true)
        }
        guard let command=resources.queue.makeCommandBuffer() else{throw GoldGPU.failure("Dragonhide command allocation")}
        var u=frame
        let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=msaa;p.colorAttachments[0].resolveTexture=resolved;p.colorAttachments[0].loadAction = .clear;p.colorAttachments[0].storeAction = .multisampleResolve;p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        p.depthAttachment.texture=depth;p.depthAttachment.loadAction = .clear;p.depthAttachment.storeAction = .dontCare;p.depthAttachment.clearDepth=1
        let e=command.makeRenderCommandEncoder(descriptor:p)!;e.setRenderPipelineState(scalesPipeline);e.setDepthStencilState(depthState);e.setCullMode(.none)
        e.setVertexBytes(&u,length:MemoryLayout<GoldUniforms>.stride,index:0);e.setVertexBuffer(vertices,offset:0,index:1);e.setFragmentBytes(&u,length:MemoryLayout<GoldUniforms>.stride,index:0);e.setFragmentTexture(resources.environment,index:0)
        e.setScissorRect(bounds(frame,width:target.width,height:target.height))
        e.drawIndexedPrimitives(type:.triangle,indexCount:indexCount,indexType:.uint32,indexBuffer:indices,indexBufferOffset:0);e.endEncoding()
        if let source{let b=command.makeBlitCommandEncoder()!;b.copy(from:source,to:target);b.endEncoding()}
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=source==nil ? .dontCare:.load;pass.colorAttachments[0].storeAction = .store
        let c=command.makeRenderCommandEncoder(descriptor:pass)!;c.setRenderPipelineState(compositePipeline);c.setFragmentBytes(&u,length:MemoryLayout<GoldUniforms>.stride,index:0)
        c.setFragmentTexture(source ?? resources.dummy,index:0);c.setFragmentTexture(resolved,index:1)
        if source != nil{c.setScissorRect(bounds(frame,width:target.width,height:target.height))}
        c.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);c.endEncoding()
        if let drawable{command.present(drawable)}
        command.commit();if wait{command.waitUntilCompleted();if let error=command.error{throw error}}
        return command
    }
}
