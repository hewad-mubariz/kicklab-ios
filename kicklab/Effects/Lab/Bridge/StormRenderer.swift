// Copied from the Effects Lab (EffectLab/StormRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo

nonisolated final class StormGPU {
 let device:MTLDevice,queue:MTLCommandQueue
 let densityPipeline,lightPipeline:MTLComputePipelineState
 let pipeline:MTLRenderPipelineState
 let density,lighting:MTLTexture
 var cache:CVMetalTextureCache!
 init(libraryURL:URL)throws {
  guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else {throw Self.failure("Metal unavailable")}
  device=d;queue=q;let lib=try d.makeLibrary(URL:libraryURL)
  densityPipeline=try d.makeComputePipelineState(function:lib.makeFunction(name:"stormDensity")!)
  lightPipeline=try d.makeComputePipelineState(function:lib.makeFunction(name:"stormLight")!)
  let td=MTLTextureDescriptor();td.textureType = .type3D;td.pixelFormat = .r16Float;td.width=256;td.height=256;td.depth=112;td.usage=[.shaderRead,.shaderWrite];td.storageMode = .private
  density=d.makeTexture(descriptor:td)!
  td.pixelFormat = .rgba16Float;lighting=d.makeTexture(descriptor:td)!
  let p=MTLRenderPipelineDescriptor();p.vertexFunction=lib.makeFunction(name:"stormVertex");p.fragmentFunction=lib.makeFunction(name:"stormFragment");p.colorAttachments[0].pixelFormat = .bgra8Unorm
  pipeline=try d.makeRenderPipelineState(descriptor:p)
  guard CVMetalTextureCacheCreate(nil,nil,d,nil,&cache)==kCVReturnSuccess else {throw Self.failure("Video texture cache")}
 }
 static func failure(_ message:String)->NSError {NSError(domain:"StormLab",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
 func reset()throws {}
 func makeTexture(width:Int,height:Int)->MTLTexture {
  let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false);td.storageMode = .shared;td.usage=[.renderTarget,.shaderRead]
  return device.makeTexture(descriptor:td)!
 }
 func texture(_ pixels:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture) {
  var ref:CVMetalTexture?
  guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&ref)==kCVReturnSuccess,let ref,let texture=CVMetalTextureGetTexture(ref) else {throw Self.failure("Video texture mapping")}
  return (ref,texture)
 }
 @discardableResult func render(frame:StormFrame,source:MTLTexture,target:MTLTexture)throws->MTLCommandBuffer {
  let command=queue.makeCommandBuffer()!;var u=frame.uniforms
  let blit=command.makeBlitCommandEncoder()!;blit.copy(from:source,to:target);blit.endEncoding()
  if u.viewport.w>0 && u.ball.w>0 && !frame.lobes.isEmpty {
   let lobes=frame.lobes.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
   let segs=frame.bolts.isEmpty ? [StormSegment(a:.zero,b:.zero)]:frame.bolts
   let bolts=segs.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
   let c=command.makeComputeCommandEncoder()!;c.setComputePipelineState(densityPipeline);c.setBytes(&u,length:MemoryLayout<StormUniforms>.stride,index:0);c.setBuffer(lobes,offset:0,index:1);c.setTexture(density,index:0)
   let grid=MTLSize(width:density.width,height:density.height,depth:density.depth),group=MTLSize(width:4,height:4,depth:4)
   c.dispatchThreads(grid,threadsPerThreadgroup:group);c.endEncoding()
   let l=command.makeComputeCommandEncoder()!;l.setComputePipelineState(lightPipeline);l.setBytes(&u,length:MemoryLayout<StormUniforms>.stride,index:0);l.setBuffer(bolts,offset:0,index:1);l.setTexture(density,index:0);l.setTexture(lighting,index:1);l.dispatchThreads(grid,threadsPerThreadgroup:group);l.endEncoding()
   let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction = .load;pass.colorAttachments[0].storeAction = .store
   let e=command.makeRenderCommandEncoder(descriptor:pass)!;e.setRenderPipelineState(pipeline);e.setFragmentBytes(&u,length:MemoryLayout<StormUniforms>.stride,index:0);e.setFragmentBuffer(bolts,offset:0,index:1);e.setFragmentTexture(source,index:0);e.setFragmentTexture(density,index:1);e.setFragmentTexture(lighting,index:2)
   e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding()
  }
  command.commit();command.waitUntilCompleted();if let error=command.error{throw error};return command
 }
}
