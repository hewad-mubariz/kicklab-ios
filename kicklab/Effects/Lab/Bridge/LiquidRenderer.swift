// Copied from the Effects Lab (EffectLab/LiquidRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo
import simd

nonisolated final class LiquidGPU {
    let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLRenderPipelineState,splatPipeline:MTLRenderPipelineState
    private var field:MTLTexture?
    let dummy:MTLTexture
    var cache:CVMetalTextureCache!
    init(device:MTLDevice?=MTLCreateSystemDefaultDevice(),libraryURL:URL?=nil) throws {
        guard let device,let queue=device.makeCommandQueue() else {throw Self.failure("Metal unavailable")}
        self.device=device;self.queue=queue
        let library:MTLLibrary
        if let libraryURL {library=try device.makeLibrary(URL:libraryURL)}
        else if let lib=device.makeDefaultLibrary() {library=lib}
        else {throw Self.failure("Liquid shader library unavailable")}
        let d=MTLRenderPipelineDescriptor()
        d.vertexFunction=library.makeFunction(name:"liquidVertex");d.fragmentFunction=library.makeFunction(name:"liquidFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try device.makeRenderPipelineState(descriptor:d)
        let splat=MTLRenderPipelineDescriptor()
        splat.vertexFunction=library.makeFunction(name:"liquidSplatVertex")
        splat.fragmentFunction=library.makeFunction(name:"liquidSplatFragment")
        let color=splat.colorAttachments[0]!
        color.pixelFormat = .rgba16Float;color.isBlendingEnabled=true
        color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one;color.destinationAlphaBlendFactor = .one
        splatPipeline=try device.makeRenderPipelineState(descriptor:splat)
        let texture=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1,height:1,mipmapped:false)
        texture.storageMode = .shared;texture.usage = .shaderRead
        guard let dummy=device.makeTexture(descriptor:texture) else {throw Self.failure("Texture allocation")}
        self.dummy=dummy
        var white:UInt32=0xffffffff;dummy.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&white,bytesPerRow:4)
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess else {throw Self.failure("Video texture cache")}
    }
    static func failure(_ message:String)->NSError {NSError(domain:"LiquidLab",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    func makeTexture(width:Int,height:Int)->MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        d.storageMode = .shared;d.usage=[.renderTarget,.shaderRead]
        return device.makeTexture(descriptor:d)!
    }
    func texture(_ pixels:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture) {
        var ref:CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&ref)==kCVReturnSuccess,
              let ref,let texture=CVMetalTextureGetTexture(ref) else {throw Self.failure("Video texture mapping")}
        return (ref,texture)
    }
    func bounds(_ frame:LiquidFrame,width:Int,height:Int)->MTLScissorRect {
        var low=SIMD2<Float>(repeating:Float(width+height)),high=SIMD2<Float>(repeating:0)
        for p in frame.parts {
            let extent=p.centerSize.w*2*max(p.shape.x,p.shape.y)+3
            let center=SIMD2(p.centerSize.x,p.centerSize.y)
            low=simd_min(low,center-SIMD2(repeating:extent));high=simd_max(high,center+SIMD2(repeating:extent))
        }
        let x0=max(0,min(width-1,Int(floor(low.x)))),y0=max(0,min(height-1,Int(floor(low.y))))
        let x1=max(x0+1,min(width,Int(ceil(high.x)))),y1=max(y0+1,min(height,Int(ceil(high.y))))
        return MTLScissorRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
    }
    @discardableResult func render(frame:LiquidFrame,source:MTLTexture?,target:MTLTexture,drawable:CAMetalDrawable?=nil,wait:Bool=true)throws->MTLCommandBuffer {
        guard let command=queue.makeCommandBuffer() else {throw Self.failure("Command allocation")}
        if let source {let blit=command.makeBlitCommandEncoder()!;blit.copy(from:source,to:target);blit.endEncoding()}
        if field?.width != target.width || field?.height != target.height {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:target.width,height:target.height,mipmapped:false)
            d.storageMode = .private;d.usage=[.renderTarget,.shaderRead]
            field=device.makeTexture(descriptor:d)
        }
        guard let field else {throw Self.failure("Fluid field allocation")}
        var uniforms=frame.uniforms
        let parts=frame.parts.isEmpty ? [LiquidPart(centerSize:.zero,shape:.zero,material:.zero)]:frame.parts
        let buffer=parts.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
        let densityPass=MTLRenderPassDescriptor();densityPass.colorAttachments[0].texture=field
        densityPass.colorAttachments[0].loadAction = .clear;densityPass.colorAttachments[0].storeAction = .store
        densityPass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        let splat=command.makeRenderCommandEncoder(descriptor:densityPass)!
        splat.setRenderPipelineState(splatPipeline)
        splat.setVertexBytes(&uniforms,length:MemoryLayout<LiquidUniforms>.stride,index:0)
        splat.setVertexBuffer(buffer,offset:0,index:1)
        if !frame.parts.isEmpty {splat.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:frame.parts.count)}
        splat.endEncoding()
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction=source == nil ? .dontCare:.load;pass.colorAttachments[0].storeAction = .store
        let e=command.makeRenderCommandEncoder(descriptor:pass)!
        e.setRenderPipelineState(pipeline)
        if source != nil {e.setScissorRect(bounds(frame,width:target.width,height:target.height))}
        e.setFragmentBytes(&uniforms,length:MemoryLayout<LiquidUniforms>.stride,index:0)
        e.setFragmentTexture(source ?? dummy,index:0);e.setFragmentTexture(field,index:1)
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding()
        if let drawable {command.present(drawable)}
        command.commit()
        if wait {command.waitUntilCompleted();if let error=command.error {throw error}}
        return command
    }
}
