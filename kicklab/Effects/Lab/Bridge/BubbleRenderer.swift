// Copied from the Effects Lab (EffectLab/BubbleRenderer.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import MetalKit
import CoreVideo

nonisolated final class BubbleGPU {
 let waterGPU:WaterGPU
 let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLRenderPipelineState
 private var backdrop:MTLTexture?
 var lastWaterMilliseconds:Double=0
 init(libraryURL:URL)throws {
  waterGPU=try WaterGPU(libraryURL:libraryURL);device=waterGPU.device;queue=waterGPU.queue
  let lib=try device.makeLibrary(URL:libraryURL),p=MTLRenderPipelineDescriptor()
  p.vertexFunction=lib.makeFunction(name:"bubbleVertex");p.fragmentFunction=lib.makeFunction(name:"bubbleFragment")
  let c=p.colorAttachments[0]!;c.pixelFormat = .bgra8Unorm;c.isBlendingEnabled=true
  c.sourceRGBBlendFactor = .one;c.destinationRGBBlendFactor = .oneMinusSourceAlpha;c.sourceAlphaBlendFactor = .one;c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
  pipeline=try device.makeRenderPipelineState(descriptor:p)
 }
 static func failure(_ message:String)->NSError {NSError(domain:"BubbleLab",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
 func makeTexture(width:Int,height:Int)->MTLTexture {waterGPU.makeTexture(width:width,height:height)}
 func texture(_ buffer:CVPixelBuffer)throws->(CVMetalTexture,MTLTexture){try waterGPU.texture(buffer)}
 func reset()throws {} // Analytic bubbles and deterministically cached shared water.
 @discardableResult func render(frame:BubbleFrame,source:MTLTexture,target:MTLTexture)throws->MTLCommandBuffer {
  if backdrop?.width != source.width || backdrop?.height != source.height {backdrop=makeTexture(width:source.width,height:source.height)}
  let water=try waterGPU.render(frame:frame.water,source:source,target:backdrop!)
  lastWaterMilliseconds=(water.gpuEndTime-water.gpuStartTime)*1000
  let command=queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!;blit.copy(from:backdrop!,to:target);blit.endEncoding()
  var u=frame.uniforms
  if u.viewport.w>0 && u.ball.w>0 && !frame.bubbles.isEmpty {
   let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=target;p.colorAttachments[0].loadAction = .load;p.colorAttachments[0].storeAction = .store
   let e=command.makeRenderCommandEncoder(descriptor:p)!
   e.setRenderPipelineState(pipeline);e.setVertexBytes(&u,length:MemoryLayout<BubbleUniforms>.stride,index:0);e.setFragmentBytes(&u,length:MemoryLayout<BubbleUniforms>.stride,index:0)
   let buffer=frame.bubbles.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}!
   e.setVertexBuffer(buffer,offset:0,index:1);e.setFragmentTexture(backdrop!,index:0)
   e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:frame.bubbles.count);e.endEncoding()
  }
  command.commit();command.waitUntilCompleted();if let error=command.error {throw error};return command
 }
}
