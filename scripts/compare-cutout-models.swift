// Diagnostic only: compare Vision's mask families on identical local source crops.
import AVFoundation
import CoreImage
import Foundation
import Metal
import Vision

@main struct CutoutComparison {
    static func main() async throws {
        let a=CommandLine.arguments, folder=URL(fileURLWithPath:a[3])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let report=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:a[2]))) as! [String:Any]
        let rect=report["crop"] as! [Double]
        let crop=CGRect(x:rect[0],y:rect[1],width:rect[2],height:rect[3])
        let asset=AVURLAsset(url:URL(fileURLWithPath:a[1]))
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let context=CIContext(mtlDevice:MTLCreateSystemDefaultDevice()!)
        let times=a.dropFirst(4).compactMap(Double.init)
        for time in times {
            let cg=try await generator.image(at:CMTime(seconds:time,preferredTimescale:60000)).image
            let native=CIImage(cgImage:cg)
            for shortEdge in [720,2160] {
                let scale=min(1,Double(shortEdge)/Double(cg.width))
                let source=native.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                let extent=source.extent
                let box=CGRect(x:crop.minX*extent.width,y:(1-crop.maxY)*extent.height,width:crop.width*extent.width,height:crop.height*extent.height).integral
                let input=source.cropped(to:box).transformed(by:CGAffineTransform(translationX:-box.minX,y:-box.minY))
                let image=context.createCGImage(input,from:input.extent)!
                let stem="\(Int(time*1000))-\(shortEdge)"
                func save(_ ci:CIImage,_ name:String) throws {
                    try context.writePNGRepresentation(of:ci,to:folder.appendingPathComponent(stem+"-"+name+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                }
                try save(input,"source")
                for family in ["accurate","person-instance","foreground-instance"] {
                    let handler=VNImageRequestHandler(cgImage:image,orientation:.up)
                    let start=Date();let mask:CVPixelBuffer
                    if family=="accurate" {
                        let request=VNGeneratePersonSegmentationRequest();request.qualityLevel = .accurate
                        try handler.perform([request]);mask=request.results!.first!.pixelBuffer
                    } else {
                        let observation:VNInstanceMaskObservation
                        if family=="person-instance" {
                            let request=VNGeneratePersonInstanceMaskRequest();try handler.perform([request]);observation=request.results!.first!
                        } else {
                            let request=VNGenerateForegroundInstanceMaskRequest();try handler.perform([request]);observation=request.results!.first!
                        }
                        mask=try observation.generateScaledMaskForImage(forInstances:observation.allInstances,from:handler)
                    }
                    var alpha=CIImage(cvPixelBuffer:mask)
                    alpha=alpha.transformed(by:CGAffineTransform(scaleX:input.extent.width/alpha.extent.width,y:input.extent.height/alpha.extent.height))
                    let bg=CIImage(color:CIColor(red:0.17,green:0.10,blue:0.22)).cropped(to:input.extent)
                    let composite=input.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:bg,kCIInputMaskImageKey:alpha])
                    try save(alpha,family+"-mask");try save(composite,family)
                    print("\(stem) \(family): \(CVPixelBufferGetWidth(mask))x\(CVPixelBufferGetHeight(mask)), \(Date().timeIntervalSince(start))s")
                }
            }
        }
    }
}
