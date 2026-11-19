// Copied from the Effects Lab (EffectLab/SilkRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo

nonisolated final class SilkGPU {
 let device:MTLDevice,queue:MTLCommandQueue
 let ribbonsPipeline,compositePipeline:MTLRenderPipelineState
 let depthState:MTLDepthStencilState
 var cache:CVMetalTextureCache!
 private var msaa:MTLTexture?,colors=[MTLTexture](),depthSamples=[MTLTexture](),depths=[MTLTexture]()
 init(libraryURL:URL)throws {
  guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else{throw Self.failure("Metal unavailable")}
  device=d;queue=q;let library=try device.makeLibrary(URL:libraryURL)
  let p=MTLRenderPipelineDescriptor();p.vertexFunction=library.makeFunction(name:"silkVertex");p.fragmentFunction=library.makeFunction(name:"silkFragment");p.rasterSampleCount=4
  p.colorAttachments[0].pixelFormat = .rgba16Float;p.depthAttachmentPixelFormat = .depth32Float
  ribbonsPipeline=try d.makeRenderPipelineState(descriptor:p)
  let c=MTLRenderPipelineDescriptor();c.vertexFunction=library.makeFunction(name:"silkCompositeVertex");c.fragmentFunction=library.makeFunction(name:"silkComposite")
  let blend=c.colorAttachments[0]!;blend.pixelFormat = .bgra8Unorm;blend.isBlendingEnabled=true;blend.sourceRGBBlendFactor = .one;blend.destinationRGBBlendFactor = .oneMinusSourceAlpha;blend.sourceAlphaBlendFactor = .one;blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
  compositePipeline=try d.makeRenderPipelineState(descriptor:c)
  let depth=MTLDepthStencilDescriptor();depth.depthCompareFunction = .less;depth.isDepthWriteEnabled=true;depthState=d.makeDepthStencilState(descriptor:depth)!
  guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess else{throw Self.failure("Video texture cache")}
 }
 static func failure(_ message:String)->NSError {NSError(domain:"SilkLab",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
 func reset()throws {}
 func makeTexture(width:Int,height:Int)->MTLTexture {
  let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false);d.storageMode = .shared;d.usage=[.renderTarget,.shaderRead];return device.makeTexture(descriptor:d)!
 }
 func texture(_ pixels:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture) {
  var ref:CVMetalTexture?
  guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&ref)==kCVReturnSuccess,let ref,let texture=CVMetalTextureGetTexture(ref) else{throw Self.failure("Video texture mapping")}
  return (ref,texture)
 }
 @discardableResult func render(frame:SilkFrame,source:MTLTexture,target:MTLTexture)throws->MTLCommandBuffer {
  if msaa?.width != source.width || msaa?.height != source.height {
   func layer(_ format:MTLPixelFormat,_ samples:Int)->MTLTexture {
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:source.width,height:source.height,mipmapped:false);d.storageMode = .private;d.usage=[.renderTarget,.shaderRead]
    if samples>1 {d.textureType = .type2DMultisample;d.sampleCount=samples}
    return device.makeTexture(descriptor:d)!
   }
   msaa=layer(.rgba16Float,4);colors=(0..<4).map{_ in layer(.rgba16Float,1)};depthSamples=(0..<4).map{_ in layer(.depth32Float,4)};depths=(0..<4).map{_ in layer(.depth32Float,1)}
  }
  let command=queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!;blit.copy(from:source,to:target);blit.endEncoding()
  var u=frame.uniforms
  if u.viewport.w>0 && u.ball.w>0 && !frame.ribbons.isEmpty {
   let buffer=frame.ribbons.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
   let nodeBuffer=frame.nodes.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
   // Peel four actual depth layers. Near opaque folds occlude rear surfaces;
   // thin fabric still transmits the remaining layers in front-to-back order.
   for layer in 0..<4 {
    u.peel.x=Float(layer)
    let p=MTLRenderPassDescriptor();let a=p.colorAttachments[0]!
    a.texture=msaa;a.resolveTexture=colors[layer];a.loadAction = .clear;a.storeAction = .multisampleResolve;a.clearColor=MTLClearColorMake(0,0,0,0)
    let depth=p.depthAttachment!;depth.texture=depthSamples[layer];depth.resolveTexture=depths[layer];depth.loadAction = .clear;depth.storeAction = .storeAndMultisampleResolve;depth.depthResolveFilter = .min;depth.clearDepth=1
    let e=command.makeRenderCommandEncoder(descriptor:p)!;e.setRenderPipelineState(ribbonsPipeline);e.setDepthStencilState(depthState);e.setCullMode(.none)
    e.setVertexBytes(&u,length:MemoryLayout<SilkUniforms>.stride,index:0);e.setFragmentBytes(&u,length:MemoryLayout<SilkUniforms>.stride,index:0)
    e.setVertexBuffer(buffer,offset:0,index:1);e.setVertexBuffer(nodeBuffer,offset:0,index:2);e.setFragmentTexture(depthSamples[layer==0 ? 3:layer-1],index:0)
    e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:240*32*6,instanceCount:frame.ribbons.count);e.endEncoding()
   }
   let c=MTLRenderPassDescriptor();c.colorAttachments[0].texture=target;c.colorAttachments[0].loadAction = .load;c.colorAttachments[0].storeAction = .store
   let composite=command.makeRenderCommandEncoder(descriptor:c)!;composite.setRenderPipelineState(compositePipeline)
   for i in 0..<4 {composite.setFragmentTexture(colors[i],index:i);composite.setFragmentTexture(depths[i],index:4+i)}
   composite.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);composite.endEncoding()
  }
  command.commit();command.waitUntilCompleted();if let error=command.error{throw error};return command
 }
}
