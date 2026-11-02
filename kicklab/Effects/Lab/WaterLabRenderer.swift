// Copied from the Effects Lab (Water, accepted 1 November 2026). Only the setup is adapted: it uses
// the effect engine's device and shader library and encodes into the engine's command buffer.
import Foundation
import Metal
import simd

nonisolated final class WaterLabRenderer {
    let device:MTLDevice,pipeline:MTLRenderPipelineState,splatPipeline:MTLRenderPipelineState
    private var field:MTLTexture?
    private var temporary, filtered:MTLTexture?
    private let smoothPipeline:MTLComputePipelineState
    private let frontPipeline:MTLRenderPipelineState,bilateralPipeline:MTLComputePipelineState
    private var front,frontTemp,frontFiltered:MTLTexture?
    private let dropPipeline:MTLRenderPipelineState
    private let surfacePipeline:MTLRenderPipelineState, depthState:MTLDepthStencilState
    private var depth:MTLTexture?
    let dummy:MTLTexture
    init(device:MTLDevice,library:MTLLibrary) throws {
        guard library.makeFunction(name:"waterSmooth") != nil else {throw Self.failure("Water shaders are missing")}
        self.device=device
        smoothPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"waterSmooth")!)
        bilateralPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"waterBilateral")!)
        let frontDescriptor=MTLRenderPipelineDescriptor()
        frontDescriptor.vertexFunction=library.makeFunction(name:"waterFrontVertex")
        frontDescriptor.fragmentFunction=library.makeFunction(name:"waterFrontFragment")
        let frontColor=frontDescriptor.colorAttachments[0]!
        frontColor.pixelFormat = .rgba32Float;frontColor.isBlendingEnabled=true
        frontColor.rgbBlendOperation = .max;frontColor.alphaBlendOperation = .max
        frontColor.sourceRGBBlendFactor = .one;frontColor.destinationRGBBlendFactor = .one
        frontColor.sourceAlphaBlendFactor = .one;frontColor.destinationAlphaBlendFactor = .one
        frontPipeline=try device.makeRenderPipelineState(descriptor:frontDescriptor)
        let d=MTLRenderPipelineDescriptor()
        d.vertexFunction=library.makeFunction(name:"waterVertex");d.fragmentFunction=library.makeFunction(name:"waterFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try device.makeRenderPipelineState(descriptor:d)
        let splat=MTLRenderPipelineDescriptor()
        splat.vertexFunction=library.makeFunction(name:"waterSplatVertex")
        splat.fragmentFunction=library.makeFunction(name:"waterSplatFragment")
        let color=splat.colorAttachments[0]!
        color.pixelFormat = .rgba32Float;color.isBlendingEnabled=true
        color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one;color.destinationAlphaBlendFactor = .one
        splatPipeline=try device.makeRenderPipelineState(descriptor:splat)
        let drops=MTLRenderPipelineDescriptor()
        drops.vertexFunction=library.makeFunction(name:"waterDropVertex")
        drops.fragmentFunction=library.makeFunction(name:"waterDropFragment")
        drops.colorAttachments[0].pixelFormat = .bgra8Unorm
        drops.colorAttachments[0].isBlendingEnabled=true
        drops.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        drops.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        drops.colorAttachments[0].sourceAlphaBlendFactor = .one
        drops.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        dropPipeline=try device.makeRenderPipelineState(descriptor:drops)
        let mesh=MTLRenderPipelineDescriptor()
        mesh.vertexFunction=library.makeFunction(name:"waterSurfaceVertex")
        mesh.fragmentFunction=library.makeFunction(name:"waterSurfaceFragment")
        mesh.colorAttachments[0].pixelFormat = .bgra8Unorm;mesh.depthAttachmentPixelFormat = .depth32Float
        mesh.colorAttachments[0].isBlendingEnabled=true
        mesh.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha;mesh.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        mesh.colorAttachments[0].sourceAlphaBlendFactor = .one;mesh.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        surfacePipeline=try device.makeRenderPipelineState(descriptor:mesh)
        let depthConfig=MTLDepthStencilDescriptor();depthConfig.depthCompareFunction = .lessEqual;depthConfig.isDepthWriteEnabled=true
        depthState=device.makeDepthStencilState(descriptor:depthConfig)!

        let texture=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1,height:1,mipmapped:false)
        texture.storageMode = .shared;texture.usage = .shaderRead
        guard let dummy=device.makeTexture(descriptor:texture) else {throw Self.failure("Texture allocation")}
        self.dummy=dummy
        var white:UInt32=0xffffffff;dummy.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&white,bytesPerRow:4)
    }
    static func failure(_ message:String)->NSError {NSError(domain:"WaterLab",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    func bounds(_ frame:WaterFrame,width:Int,height:Int)->MTLScissorRect {
        var low=SIMD2<Float>(repeating:Float(width+height)),high=SIMD2<Float>(repeating:0)
        for p in frame.parts {
            let extent=p.centerSize.w*2*max(p.shape.x,p.shape.y)+3+min(8,ceil(max(0.7,frame.uniforms.ball.z*0.024)*2.5))
            let center=SIMD2(p.centerSize.x,p.centerSize.y)
            low=simd_min(low,center-SIMD2(repeating:extent));high=simd_max(high,center+SIMD2(repeating:extent))
        }
        for v in frame.surface {
            let p=SIMD2(v.positionThickness.x,v.positionThickness.y)
            low=simd_min(low,p-SIMD2(repeating:3));high=simd_max(high,p+SIMD2(repeating:3))
        }
        let x0=max(0,min(width-1,Int(floor(low.x)))),y0=max(0,min(height-1,Int(floor(low.y))))
        let x1=max(x0+1,min(width,Int(ceil(high.x)))),y1=max(y0+1,min(height,Int(ceil(high.y))))
        return MTLScissorRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
    }
    func encode(frame:WaterFrame,source:MTLTexture?,target:MTLTexture,command:MTLCommandBuffer)throws {
        if let source {let blit=command.makeBlitCommandEncoder()!;blit.copy(from:source,to:target);blit.endEncoding()}
        if field?.width != target.width || field?.height != target.height {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:target.width,height:target.height,mipmapped:false)
            d.storageMode = .private;d.usage=[.renderTarget,.shaderRead,.shaderWrite]
            field=device.makeTexture(descriptor:d)
            temporary=device.makeTexture(descriptor:d);filtered=device.makeTexture(descriptor:d)
            front=device.makeTexture(descriptor:d);frontTemp=device.makeTexture(descriptor:d);frontFiltered=device.makeTexture(descriptor:d)
        }
        guard let field,let temporary,let filtered,let front,let frontTemp,let frontFiltered else {throw Self.failure("Fluid field allocation")}
        var uniforms=frame.uniforms
        let parts=frame.parts.isEmpty ? [WaterPart(centerSize:.zero,shape:.zero,material:.zero)]:frame.parts
        let buffer=parts.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
        let densityPass=MTLRenderPassDescriptor();densityPass.colorAttachments[0].texture=field
        densityPass.colorAttachments[0].loadAction = .clear;densityPass.colorAttachments[0].storeAction = .store
        densityPass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        let splat=command.makeRenderCommandEncoder(descriptor:densityPass)!
        splat.setRenderPipelineState(splatPipeline)
        splat.setVertexBytes(&uniforms,length:MemoryLayout<WaterUniforms>.stride,index:0)
        splat.setVertexBuffer(buffer,offset:0,index:1)
        if !frame.parts.isEmpty {splat.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:frame.parts.count)}
        splat.endEncoding()
        // Over footage only the splash bounds are shaded (the scissor below). The filters reach 12
        // pixels and the shading 1 more, so filtering the bounds plus 16 gives the same shaded pixels.
        let shaded=bounds(frame,width:target.width,height:target.height)
        let x0=source == nil ? 0:max(0,shaded.x-16),y0=source == nil ? 0:max(0,shaded.y-16)
        let x1=source == nil ? target.width:min(target.width,shaded.x+shaded.width+16)
        let y1=source == nil ? target.height:min(target.height,shaded.y+shaded.height+16)
        var origin=SIMD2<UInt32>(UInt32(x0),UInt32(y0))
        let filterSize=MTLSize(width:x1-x0,height:y1-y0,depth:1)
        // Smooth the particle-scale quilting before reconstructing optical normals.
        // This filters the changing water field, never the source footage.
        for direction in 0..<2 {
            let e=command.makeComputeCommandEncoder()!
            e.setComputePipelineState(smoothPipeline)
            e.setTexture(direction==0 ? field:temporary,index:0)
            e.setTexture(direction==0 ? temporary:filtered,index:1)
            var data=SIMD4<Float>(Float(direction),max(0.7,uniforms.ball.z*0.024),0,0)
            e.setBytes(&data,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
            e.setBytes(&origin,length:MemoryLayout<SIMD2<UInt32>>.stride,index:1)
            e.dispatchThreads(filterSize,threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));e.endEncoding()
        }
        let frontPass=MTLRenderPassDescriptor();frontPass.colorAttachments[0].texture=front
        frontPass.colorAttachments[0].loadAction = .clear;frontPass.colorAttachments[0].storeAction = .store
        frontPass.colorAttachments[0].clearColor=MTLClearColorMake(-100000,0,0,0)
        let f=command.makeRenderCommandEncoder(descriptor:frontPass)!
        f.setRenderPipelineState(frontPipeline);f.setVertexBytes(&uniforms,length:MemoryLayout<WaterUniforms>.stride,index:0)
        f.setVertexBuffer(buffer,offset:0,index:1)
        if !frame.parts.isEmpty {f.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:frame.parts.count)}
        f.endEncoding()
        for iteration in 0..<2 {
            let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(bilateralPipeline)
            e.setTexture(iteration==0 ? front:(iteration%2==0 ? frontFiltered:frontTemp),index:0)
            e.setTexture(iteration%2==0 ? frontTemp:frontFiltered,index:1)
            var data=SIMD4<Float>(Float(iteration%2),max(1,uniforms.ball.z*0.030),max(2,uniforms.ball.z*0.20),0)
            e.setBytes(&data,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
            e.setBytes(&origin,length:MemoryLayout<SIMD2<UInt32>>.stride,index:1)
            e.dispatchThreads(filterSize,threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));e.endEncoding()
        }
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction=source == nil ? .dontCare:.load;pass.colorAttachments[0].storeAction = .store
        let e=command.makeRenderCommandEncoder(descriptor:pass)!
        e.setRenderPipelineState(pipeline)
        if source != nil {e.setScissorRect(shaded)}
        e.setFragmentBytes(&uniforms,length:MemoryLayout<WaterUniforms>.stride,index:0)
        e.setFragmentTexture(source ?? dummy,index:0);e.setFragmentTexture(filtered,index:1);e.setFragmentTexture(frontFiltered,index:2)
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        e.endEncoding()
        if !frame.surface.isEmpty {
            if depth?.width != target.width || depth?.height != target.height {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:target.width,height:target.height,mipmapped:false)
                d.storageMode = .private;d.usage = .renderTarget;depth=device.makeTexture(descriptor:d)
            }
            let meshPass=MTLRenderPassDescriptor();meshPass.colorAttachments[0].texture=target
            meshPass.colorAttachments[0].loadAction = .load;meshPass.colorAttachments[0].storeAction = .store
            meshPass.depthAttachment.texture=depth;meshPass.depthAttachment.loadAction = .clear;meshPass.depthAttachment.storeAction = .dontCare;meshPass.depthAttachment.clearDepth=1
            let m=command.makeRenderCommandEncoder(descriptor:meshPass)!
            m.setRenderPipelineState(surfacePipeline);m.setDepthStencilState(depthState);m.setCullMode(.none)
            m.setVertexBytes(&uniforms,length:MemoryLayout<WaterUniforms>.stride,index:0)
            let vertices=frame.surface.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
            m.setVertexBuffer(vertices,offset:0,index:1)
            m.setFragmentBytes(&uniforms,length:MemoryLayout<WaterUniforms>.stride,index:0);m.setFragmentTexture(source ?? dummy,index:0)
            m.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:frame.surface.count);m.endEncoding()
        }
        if !frame.parts.isEmpty {
            pass.colorAttachments[0].loadAction = .load
            let e=command.makeRenderCommandEncoder(descriptor:pass)!
            e.setRenderPipelineState(dropPipeline)
            e.setFragmentBytes(&uniforms,length:MemoryLayout<WaterUniforms>.stride,index:0)
            e.setFragmentTexture(source ?? dummy,index:0)
            e.setVertexBytes(&uniforms,length:MemoryLayout<WaterUniforms>.stride,index:0)
            e.setVertexBuffer(buffer,offset:0,index:1)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:frame.parts.count)
            e.endEncoding()
        }
    }
}
