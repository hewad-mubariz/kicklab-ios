// Copied from the Effects Lab (EffectLab/OrigamiRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo

nonisolated final class OrigamiGPU {
 let device:MTLDevice,queue:MTLCommandQueue
 let paperPipeline,compositePipeline:MTLRenderPipelineState
 var cache:CVMetalTextureCache!
 private var msaa:MTLTexture?,resolved:MTLTexture?,depth:MTLTexture?
 let depthState:MTLDepthStencilState
 init(libraryURL:URL)throws {
  guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else{throw Self.failure("Metal unavailable")}
  device=d;queue=q;let library=try device.makeLibrary(URL:libraryURL)
  let depthDescriptor=MTLDepthStencilDescriptor();depthDescriptor.depthCompareFunction = .lessEqual;depthDescriptor.isDepthWriteEnabled=true;depthState=d.makeDepthStencilState(descriptor:depthDescriptor)!
  func pipeline(_ vertex:String,_ fragment:String,_ samples:Int)throws->MTLRenderPipelineState {
   let p=MTLRenderPipelineDescriptor();p.vertexFunction=library.makeFunction(name:vertex);p.fragmentFunction=library.makeFunction(name:fragment);p.rasterSampleCount=samples
   if samples==4 {p.depthAttachmentPixelFormat = .depth32Float}
   let c=p.colorAttachments[0]!;c.pixelFormat = .bgra8Unorm;c.isBlendingEnabled=true;c.sourceRGBBlendFactor = .one;c.destinationRGBBlendFactor = .oneMinusSourceAlpha;c.sourceAlphaBlendFactor = .one;c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
   return try d.makeRenderPipelineState(descriptor:p)
  }
  paperPipeline=try pipeline("origamiVertex","origamiFragment",4);compositePipeline=try pipeline("origamiCompositeVertex","origamiComposite",1)
  guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess else{throw Self.failure("Video texture cache")}
 }
 static func failure(_ message:String)->NSError {NSError(domain:"OrigamiLab",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
 func reset()throws {} // Analytic world-space releases are derived from birth time.
 func makeTexture(width:Int,height:Int)->MTLTexture {
  let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false);d.storageMode = .shared;d.usage=[.renderTarget,.shaderRead];return device.makeTexture(descriptor:d)!
 }
 func texture(_ pixels:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture) {
  var ref:CVMetalTexture?
  guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&ref)==kCVReturnSuccess,let ref,let texture=CVMetalTextureGetTexture(ref) else{throw Self.failure("Video texture mapping")}
  return (ref,texture)
 }
 @discardableResult func render(frame:OrigamiFrame,source:MTLTexture,target:MTLTexture)throws->MTLCommandBuffer {
  if msaa?.width != source.width || msaa?.height != source.height {
   let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:source.width,height:source.height,mipmapped:false);d.storageMode = .private;d.usage=[.renderTarget,.shaderRead];resolved=device.makeTexture(descriptor:d)
   d.textureType = .type2DMultisample;d.sampleCount=4;d.usage = .renderTarget;msaa=device.makeTexture(descriptor:d)
   d.pixelFormat = .depth32Float;depth=device.makeTexture(descriptor:d)
  }
  let command=queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!;blit.copy(from:source,to:target);blit.endEncoding()
  var u=frame.uniforms
  if u.viewport.w>0 && u.ball.w>0 && !frame.vertices.isEmpty {
   let buffer=frame.vertices.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
   let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=msaa;p.colorAttachments[0].resolveTexture=resolved;p.colorAttachments[0].loadAction = .clear;p.colorAttachments[0].storeAction = .multisampleResolve;p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
   p.depthAttachment.texture=depth;p.depthAttachment.loadAction = .clear;p.depthAttachment.storeAction = .dontCare;p.depthAttachment.clearDepth=1
   let e=command.makeRenderCommandEncoder(descriptor:p)!;e.setDepthStencilState(depthState);e.setRenderPipelineState(paperPipeline);e.setCullMode(.none);e.setVertexBytes(&u,length:MemoryLayout<OrigamiUniforms>.stride,index:0);e.setFragmentBytes(&u,length:MemoryLayout<OrigamiUniforms>.stride,index:0);e.setVertexBuffer(buffer,offset:0,index:1)
   e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:frame.vertices.count);e.endEncoding()
   let c=MTLRenderPassDescriptor();c.colorAttachments[0].texture=target;c.colorAttachments[0].loadAction = .load;c.colorAttachments[0].storeAction = .store
   let composite=command.makeRenderCommandEncoder(descriptor:c)!;composite.setRenderPipelineState(compositePipeline);composite.setFragmentTexture(resolved,index:0);composite.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);composite.endEncoding()
  }
  command.commit();command.waitUntilCompleted();if let error=command.error{throw error};return command
 }
}
