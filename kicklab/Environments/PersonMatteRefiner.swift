import Accelerate
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Offline person-only refinement. The ball retains its independent mask.
/// Known foreground/background constrain a learned estimate in the uncertain
/// boundary and in places where the two Vision masks disagree.
nonisolated final class PersonMatteRefiner {
    static let modelName = "PersonBoundaryMatte"
    static let version = "vitmatte-small-768-r3"
    private let model: MLModel
    private let context: CIContext
    private let edge = 768
    private let input: MLMultiArray

    init(modelURL: URL, context: CIContext) throws {
        self.context = context
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf:modelURL,configuration:configuration)
        input = try MLMultiArray(shape:[1,4,768,768],dataType:.float32)
    }

    func process(source: CVPixelBuffer, alpha: CVPixelBuffer, guide: CVPixelBuffer, original: CVPixelBuffer? = nil) throws -> CVPixelBuffer {
        let w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source)==kCVPixelFormatType_32BGRA else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        let a=try gray(alpha,width:w,height:h),g=try gray(guide,width:w,height:h)
        let trusted=try original.map {try gray($0,width:w,height:h)} ?? a
        let radius=max(3,min(63,Int((Double(max(w,h))*31/1187).rounded())))
        let constraints=try Self.constraints(alpha:a,guide:g,width:w,height:h,radius:radius,original:trusted)
        let trimap=constraints.trimap
        let scale=min(1,Double(edge)/Double(max(w,h)))
        let sw=max(1,Int((Double(w)*scale).rounded())),sh=max(1,Int((Double(h)*scale).rounded()))
        let small=try ForegroundMaskProcessor.buffer(width:sw,height:sh,format:kCVPixelFormatType_32BGRA)
        let resized=CIImage(cvPixelBuffer:source).applyingFilter("CILanczosScaleTransform",parameters:[
            kCIInputScaleKey:Double(sh)/Double(h),kCIInputAspectRatioKey:(Double(sw)/Double(w))/(Double(sh)/Double(h))])
        context.render(resized,to:small)
        let values=input.dataPointer.assumingMemoryBound(to:Float.self),plane=edge*edge
        memset(values,0,input.count*MemoryLayout<Float>.size)
        CVPixelBufferLockBaseAddress(small,.readOnly)
        let rgb=CVPixelBufferGetBaseAddress(small)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(small)
        for y in 0..<sh {for x in 0..<sw {
            let i=y*edge+x,p=y*row+x*4
            values[i]=Float(rgb[p+2])/127.5-1
            values[plane+i]=Float(rgb[p+1])/127.5-1
            values[2*plane+i]=Float(rgb[p])/127.5-1
            let tx=min(w-1,Int((Double(x)+0.5)*Double(w)/Double(sw)))
            let ty=min(h-1,Int((Double(y)+0.5)*Double(h)/Double(sh)))
            values[3*plane+i]=Float(trimap[ty*w+tx])/255
        }}
        CVPixelBufferUnlockBaseAddress(small,.readOnly)
        let features=try MLDictionaryFeatureProvider(dictionary:["pixels":MLFeatureValue(multiArray:input)])
        guard let prediction=try model.prediction(from:features).featureValue(for:"alpha")?.multiArrayValue,
              prediction.dataType == .float32,prediction.shape.map(\.intValue)==[1,1,edge,edge] else {
            throw ForegroundMaskProcessor.Failure.missingMask
        }
        let result=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(result,[])
        defer {CVPixelBufferUnlockBaseAddress(result,[])}
        let out=CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to:UInt8.self),outRow=CVPixelBufferGetBytesPerRow(result)
        let predicted=prediction.dataPointer.assumingMemoryBound(to:Float.self),ys=prediction.strides[2].intValue,xs=prediction.strides[3].intValue
        for y in 0..<h {
            let py=max(0,min(Double(sh-1),(Double(y)+0.5)*Double(sh)/Double(h)-0.5)),y0=Int(py),y1=min(sh-1,y0+1),fy=Float(py-Double(y0))
            for x in 0..<w {
                let known=constraints.agreement[y*w+x]>0 ? 255:trimap[y*w+x]
                if known != 128 {out[y*outRow+x]=known;continue}
                let px=max(0,min(Double(sw-1),(Double(x)+0.5)*Double(sw)/Double(w)-0.5)),x0=Int(px),x1=min(sw-1,x0+1),fx=Float(px-Double(x0))
                let top=predicted[y0*ys+x0*xs]*(1-fx)+predicted[y0*ys+x1*xs]*fx
                let bottom=predicted[y1*ys+x0*xs]*(1-fx)+predicted[y1*ys+x1*xs]*fx
                let value=top*(1-fy)+bottom*fy
                guard value.isFinite else {throw ForegroundMaskProcessor.Failure.missingMask}
                out[y*outRow+x]=UInt8((max(0,min(1,value))*255).rounded())
            }
        }
        return result
    }

    private func gray(_ pixels: CVPixelBuffer,width: Int,height: Int) throws -> [UInt8] {
        guard CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_OneComponent8 else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        var buffer=pixels
        if CVPixelBufferGetWidth(pixels) != width || CVPixelBufferGetHeight(pixels) != height {
            buffer=try ForegroundMaskProcessor.buffer(width:width,height:height,format:kCVPixelFormatType_OneComponent8)
            let image=CIImage(cvPixelBuffer:pixels,options:[.colorSpace:NSNull()])
            context.render(image.transformed(by:CGAffineTransform(scaleX:Double(width)/image.extent.width,y:Double(height)/image.extent.height)),
                           to:buffer,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:nil)
        }
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        let p=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(buffer)
        var bytes=[UInt8](repeating:0,count:width*height)
        for y in 0..<height {bytes.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by:y*width).update(from:p.advanced(by:y*row),count:width) }}
        return bytes
    }

    static func trimap(alpha: [UInt8],guide: [UInt8],width: Int,height: Int,radius: Int,original: [UInt8]? = nil) throws -> [UInt8] {
        try constraints(alpha:alpha,guide:guide,width:width,height:height,radius:radius,original:original).trimap
    }

    static func constraints(alpha: [UInt8],guide: [UInt8],width: Int,height: Int,radius: Int,original: [UInt8]? = nil) throws -> (trimap:[UInt8],agreement:[UInt8]) {
        guard width>0,height>0,alpha.count==width*height,guide.count==alpha.count,radius>=0 else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        let trusted=original ?? alpha
        guard trusted.count==alpha.count else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        // The caller supplies only the selected body guide. Keep uncertain
        // guide support here: filtering it by thickness/confidence alone also
        // removes visible moving feet that subject lifting missed entirely.
        var core=alpha.map {$0>=250 ? UInt8(255):0},possible=zip(alpha,guide).map {$0>=3 || $1>=26 ? UInt8(255):0}
        var consensus=zip(trusted,guide).map {$0>=250 && $1>=250 ? UInt8(255):0}
        func morphology(_ input: inout [UInt8],radius: Int,minimum: Bool) throws -> [UInt8] {
            var output=[UInt8](repeating:0,count:input.count)
            let error=input.withUnsafeMutableBytes {src in output.withUnsafeMutableBytes {dst in
                var source=vImage_Buffer(data:src.baseAddress!,height:vImagePixelCount(height),width:vImagePixelCount(width),rowBytes:width)
                var target=vImage_Buffer(data:dst.baseAddress!,height:vImagePixelCount(height),width:vImagePixelCount(width),rowBytes:width)
                let kernel=vImagePixelCount(min(radius,(min(width,height)-1)/2)*2+1)
                return minimum ? vImageMin_Planar8(&source,&target,nil,0,0,kernel,kernel,vImage_Flags(kvImageEdgeExtend)) :
                    vImageMax_Planar8(&source,&target,nil,0,0,kernel,kernel,vImage_Flags(kvImageEdgeExtend))
            }}
            guard error==kvImageNoError else {throw ForegroundMaskProcessor.Failure.invalidFrame}
            return output
        }
        let eroded=try morphology(&core,radius:radius,minimum:true),expanded=try morphology(&possible,radius:4,minimum:false)
        // Validate the model's output separately. Changing its input trimap to
        // tiny foreground islands also changes unrelated clothing predictions.
        // Protect only an interior supported by BOTH original masks; guide-only
        // repairs remain eligible for the learned model to reject.
        let agreed=try morphology(&consensus,radius:max(1,min(4,radius/10)),minimum:true)
        return (alpha.indices.map {eroded[$0]>0 && guide[$0]>=179 ? 255:expanded[$0]>0 ? 128:0},agreed)
    }
}
