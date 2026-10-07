// SOURCE TRACK METALLIB OUTPUT_FOLDER [MODEL.mlmodelc] [MAX_FPS=30].
// Diagnostics retain the established 30 fps reference unless explicitly raised.
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The preparer invokes callbacks serially; finish is called only after it returns.
final class StageCapture: @unchecked Sendable {
    let folder:URL
    let context=CIContext()
    var manifest:[[String:Any]]=[]
    init(_ folder:URL) throws {self.folder=folder;try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
    func record(_ name:String,_ time:Double,_ pixels:CVPixelBuffer,_ rect:CGRect) throws {
        let n=Int((time*30).rounded())
        guard abs(time-Double(n)/30)<1.0/120 else {return}
        guard (55...65).contains(n) || (120...130).contains(n) || (145...155).contains(n) || (540...560).contains(n) || n==195 else {return}
        let file=String(format:"%03d-",n)+name+".png",url=folder.appendingPathComponent(file)
        let w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels)
        if name.contains("source") || name == "refined-color" {
            try context.writePNGRepresentation(of:CIImage(cvPixelBuffer:pixels),to:url,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        } else {
            CVPixelBufferLockBaseAddress(pixels,.readOnly)
            let src=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(pixels)
            let stride=CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_OneComponent8 ? 1:4
            var bytes=[UInt8](repeating:0,count:w*h)
            for y in 0..<h {for x in 0..<w {bytes[y*w+x]=src[y*row+x*stride]}}
            CVPixelBufferUnlockBaseAddress(pixels,.readOnly)
            let provider=CGDataProvider(data:Data(bytes) as CFData)!
            let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            guard let writer=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {throw ForegroundMaskProcessor.Failure.allocation}
            CGImageDestinationAddImage(writer,image,nil);guard CGImageDestinationFinalize(writer) else {throw ForegroundMaskProcessor.Failure.allocation}
        }
        manifest.append(["file":file,"stage":name,"frame":n,"time":time,"width":w,"height":h,"rect":[rect.minX,rect.minY,rect.width,rect.height]])
    }
    func finish() throws {try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("stages.json"))}
}
@main struct TraceCutout {
    static func main() async throws {
        let a=CommandLine.arguments,out=URL(fileURLWithPath:a[4]),capture=try StageCapture(out.appendingPathComponent("stages"))
        let data=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:a[2]))) as! [String:Any]
        let observations=(data["track"] as! [[String:Double]]).map {StadiumBallObservation(time:$0["time"]!,bounds:CGRect(x:$0["x"]!-$0["width"]!/2,y:$0["y"]!-$0["height"]!/2,width:$0["width"]!,height:$0["height"]!),confidence:$0["score"]!)}
        let result=try await StadiumPreviewPreparer.prepare(source:URL(fileURLWithPath:a[1]),observations:observations,library:a[3],
            personRefinerURL:a.count>5 ? URL(fileURLWithPath:a[5]):nil,
            maximumFrameRate:a.count>6 ? Double(a[6]) ?? 30:30,
            diagnostics:{name,time,pixels,rect in try capture.record(name,time,pixels,rect)})
        defer {result.removeFiles()}
        try FileManager.default.copyItem(at:result.folder,to:out.appendingPathComponent("prepared"));try capture.finish()
        print("Traced \(result.frames) frames; \(capture.manifest.count) selected stage images")
    }
}
