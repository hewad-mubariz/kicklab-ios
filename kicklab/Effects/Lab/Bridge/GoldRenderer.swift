// Copied from the Effects Lab (EffectLab/GoldRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo

nonisolated final class GoldGPU {
    let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLRenderPipelineState
    let environment:MTLTexture,dummy:MTLTexture,panels:MTLBuffer
    var cache:CVMetalTextureCache!
    init(device:MTLDevice?=MTLCreateSystemDefaultDevice(),libraryURL:URL?=nil,directory:URL?=nil)throws {
        guard let device,let queue=device.makeCommandQueue() else {throw Self.failure("Metal unavailable")}
        self.device=device;self.queue=queue
        let library:MTLLibrary
        if let libraryURL {library=try device.makeLibrary(URL:libraryURL)}
        else if let value=device.makeDefaultLibrary(){library=value}
        else {throw Self.failure("Gold shader unavailable")}
        let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:"goldVertex");d.fragmentFunction=library.makeFunction(name:"goldFragment");d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try device.makeRenderPipelineState(descriptor:d)
        panels=GoldScene.panels.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
        guard let url=directory?.appendingPathComponent("gold-environment.bin") ?? Bundle.main.url(forResource:"gold-environment",withExtension:"bin") else {throw Self.failure("Missing lighting environment")}
        let data=try Data(contentsOf:url)
        let e=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:1024,height:512,mipmapped:true);e.usage = .shaderRead
        guard data.count==(0..<e.mipmapLevelCount).reduce(0,{$0+max(1,1024 >> $1)*max(1,512 >> $1)*8}),let texture=device.makeTexture(descriptor:e) else {throw Self.failure("Invalid lighting environment")}
        data.withUnsafeBytes { bytes in
            var offset=0
            for level in 0..<e.mipmapLevelCount {
                let w=max(1,1024 >> level),h=max(1,512 >> level)
                texture.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:level,withBytes:bytes.baseAddress!+offset,bytesPerRow:w*8);offset+=w*h*8
            }
        }
        environment=texture
        let t=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1,height:1,mipmapped:false);t.storageMode = .shared;t.usage = .shaderRead
        dummy=device.makeTexture(descriptor:t)!;var zero:UInt32=0;dummy.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:4)
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess else {throw Self.failure("Video texture cache")}
    }
    static func failure(_ text:String)->NSError {NSError(domain:"GoldLab",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
    func makeTexture(width:Int,height:Int)->MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false);d.storageMode = .shared;d.usage=[.renderTarget,.shaderRead]
        return device.makeTexture(descriptor:d)!
    }
    func texture(_ pixels:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture) {
        var ref:CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&ref)==kCVReturnSuccess,let ref,let texture=CVMetalTextureGetTexture(ref) else {throw Self.failure("Video texture mapping")}
        return (ref,texture)
    }
    func bounds(_ frame:GoldUniforms,width:Int,height:Int)->MTLScissorRect {
        let b=frame.ball,r=max(0,b.z)+2
        let x=max(0,min(width-1,Int(floor(b.x-r)))),y=max(0,min(height-1,Int(floor(b.y-r))))
        return MTLScissorRect(x:x,y:y,width:max(1,min(width,Int(ceil(b.x+r)))-x),height:max(1,min(height,Int(ceil(b.y+r)))-y))
    }
    @discardableResult func render(frame:GoldUniforms,source:MTLTexture?,target:MTLTexture,drawable:CAMetalDrawable?=nil,wait:Bool=true)throws->MTLCommandBuffer {
        guard let command=queue.makeCommandBuffer() else {throw Self.failure("Command allocation")}
        if let source {let b=command.makeBlitCommandEncoder()!;b.copy(from:source,to:target);b.endEncoding()}
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=source==nil ? .dontCare:.load;pass.colorAttachments[0].storeAction = .store
        let e=command.makeRenderCommandEncoder(descriptor:pass)!
        var uniforms=frame;e.setRenderPipelineState(pipeline);e.setFragmentBytes(&uniforms,length:MemoryLayout<GoldUniforms>.stride,index:0);e.setFragmentBuffer(panels,offset:0,index:1)
        e.setFragmentTexture(source ?? dummy,index:0);e.setFragmentTexture(environment,index:1)
        if source != nil {e.setScissorRect(bounds(frame,width:target.width,height:target.height))}
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding()
        if let drawable {command.present(drawable)}
        command.commit();if wait {command.waitUntilCompleted();if let error=command.error{throw error}}
        return command
    }
}
