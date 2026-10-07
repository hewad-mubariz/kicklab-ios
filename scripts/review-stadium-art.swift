// Re-render cached source/matte pairs without repeating Vision inference.
// Usage: binary study-folder metallib output-folder [frame-second ...]
import CoreImage
import Foundation

@main struct StadiumArtReview {
    static func main() throws {
        let args=CommandLine.arguments
        let folder=URL(fileURLWithPath:args[1]), out=URL(fileURLWithPath:args[3])
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let report=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("report.json"))) as! [String:Any]
        let c=report["camera"] as! [String:Double], size=report["size"] as! [Int]
        let contacts=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("contacts.json"))) as! [[String:Double]]
        let gpu=try StadiumPreviewRenderer(library:args[2])
        let ci=CIContext(mtlDevice:gpu.device,options:[.cacheIntermediates:false])
        let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
        let times=args.dropFirst(4).compactMap(Int.init)
        for second in times.isEmpty ? [2] : times {
            var rig=SceneCameraRig(aspect:Float(size[0])/Float(size[1]),subjectHeight:Float(c["personHeight"]!),ground:SIMD2(Float(c["groundX"]!),Float(c["groundY"]!)))
            let contact=contacts.min { abs($0["time"]!-Double(second)) < abs($1["time"]!-Double(second)) }!
            rig.contact=VisibleFootContact(point:SIMD2(Float(contact["x"]!),Float(contact["y"]!)),width:Float(contact["width"]!),confidence:Float(contact["confidence"]!))
            let source=try ForegroundMaskProcessor.buffer(width:size[0],height:size[1],format:kCVPixelFormatType_32BGRA)
            let mask=try ForegroundMaskProcessor.buffer(width:size[0],height:size[1],format:kCVPixelFormatType_32BGRA)
            let target=try ForegroundMaskProcessor.buffer(width:size[0],height:size[1],format:kCVPixelFormatType_32BGRA)
            ci.render(CIImage(contentsOf:folder.appendingPathComponent("source-\(second).png"))!,to:source)
            ci.render(CIImage(contentsOf:folder.appendingPathComponent("mask-\(second).png"))!,to:mask)
            let start=Date()
            try gpu.render(source:source,mask:mask,output:target,camera:rig,time:Double(second),scene:true)
            print("\(folder.lastPathComponent) frame \(second), render \(Date().timeIntervalSince(start)*1000) ms (includes warmup)")
            try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:target),to:out.appendingPathComponent("\(folder.lastPathComponent)-\(second).png"),format:.RGBA8,colorSpace:colorSpace)
        }
    }
}
