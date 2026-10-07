import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

/// Refines the cache before encoding. Previous coverage is used only with
/// current-frame motion and color support; history resets at discontinuities.
nonisolated final class ForegroundEdgeProcessor {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let context: CIContext
    private var cache: CVMetalTextureCache?
    private var previousSmall: CVPixelBuffer?
    private var previousColor: MTLTexture?
    private var previousAlpha: CVPixelBuffer?
    private var previousTime: Double?
    private(set) var usedHistory = false

    init(device: MTLDevice, context: CIContext, library: String? = nil) throws {
        self.device=device;self.context=context
        guard let queue=device.makeCommandQueue() else {throw ForegroundMaskProcessor.Failure.allocation}
        self.queue=queue
        let lib=try library.map {try device.makeLibrary(URL:URL(fileURLWithPath:$0))} ?? device.makeDefaultLibrary()
        guard let function=lib?.makeFunction(name:"refineForegroundEdges") else {throw ForegroundMaskProcessor.Failure.allocation}
        pipeline=try device.makeComputePipelineState(function:function)
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess else {throw ForegroundMaskProcessor.Failure.allocation}
    }

    func process(color: CVPixelBuffer, mask: CVPixelBuffer, at time: Double,
                 backwardFlow: CVPixelBuffer? = nil, temporal: Bool = true) throws -> (color: CVPixelBuffer, alpha: CVPixelBuffer) {
        let w=CVPixelBufferGetWidth(color),h=CVPixelBufferGetHeight(color)
        guard time.isFinite, CVPixelBufferGetWidth(mask)==w,CVPixelBufferGetHeight(mask)==h,
              [color,mask].allSatisfy({CVPixelBufferGetPixelFormatType($0)==kCVPixelFormatType_32BGRA}) else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        let validTime=previousTime.map {time>$0 && time-$0<=0.12} ?? false
        if !temporal || !validTime || previousColor?.width != w || previousColor?.height != h {
            previousSmall=nil;previousColor=nil;previousAlpha=nil
        }
        let scale=min(1,512/Double(max(w,h))),sw=max(2,Int(Double(w)*scale)/2*2),sh=max(2,Int(Double(h)*scale)/2*2)
        let small=try ForegroundMaskProcessor.buffer(width:sw,height:sh,format:kCVPixelFormatType_32BGRA)
        context.render(CIImage(cvPixelBuffer:color).transformed(by:CGAffineTransform(scaleX:Double(sw)/Double(w),y:Double(sh)/Double(h))),to:small)
        var flow = backwardFlow
        if flow == nil, let prior=previousSmall {
            flow=try autoreleasepool {
                // Current -> previous, for backward sampling at current pixels.
                let request=VNGenerateOpticalFlowRequest(targetedCVPixelBuffer:prior,orientation:.up)
                request.computationAccuracy = .high
                request.outputPixelFormat=kCVPixelFormatType_TwoComponent32Float
                try VNImageRequestHandler(cvPixelBuffer:small,orientation:.up).perform([request])
                return request.results?.first?.pixelBuffer
            }
        }
        let result=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_32BGRA)
        let alpha=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_32BGRA)
        var refs:[CVMetalTexture]=[]
        func texture(_ b:CVPixelBuffer,format:MTLPixelFormat = .bgra8Unorm)throws->MTLTexture {
            var ref:CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil,cache!,b,nil,format,CVPixelBufferGetWidth(b),CVPixelBufferGetHeight(b),0,&ref)==kCVReturnSuccess,
                  let ref,let t=CVMetalTextureGetTexture(ref) else {throw ForegroundMaskProcessor.Failure.allocation}
            refs.append(ref);return t
        }
        let source=try texture(color),maskTexture=try texture(mask),target=try texture(result),alphaTarget=try texture(alpha)
        let historyAlpha=try previousAlpha.map {try texture($0)} ?? maskTexture
        let flowTexture=try flow.map {try texture($0,format:.rg32Float)} ?? maskTexture
        usedHistory=flow != nil && previousColor != nil && previousAlpha != nil
        var enabled:UInt32=usedHistory ? 1:0
        guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else {throw ForegroundMaskProcessor.Failure.allocation}
        encoder.setComputePipelineState(pipeline)
        for (i,t) in [source,maskTexture,previousColor ?? source,historyAlpha,flowTexture,target,alphaTarget].enumerated() {encoder.setTexture(t,index:i)}
        encoder.setBytes(&enabled,length:MemoryLayout<UInt32>.size,index:0)
        encoder.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1));encoder.endEncoding()
        if previousColor == nil {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
            descriptor.usage = [.shaderRead];previousColor=device.makeTexture(descriptor:descriptor)
        }
        guard let history=previousColor,let blit=command.makeBlitCommandEncoder() else {throw ForegroundMaskProcessor.Failure.allocation}
        blit.copy(from:source,to:history);blit.endEncoding()
        command.commit();command.waitUntilCompleted();if let error=command.error {throw error}
        withExtendedLifetime(refs) {}
        previousSmall=small;previousAlpha=alpha;previousTime=time
        return (result,alpha)
    }
}
