// Render the native arena with the existing iPhone foreground cache.
// Usage: review-indoor <prepared-folder> <metallib> <output-folder>
import AVFoundation
import CoreImage
import Foundation
import Metal

@main struct ReviewIndoorArena {
    static func main() async throws {
        let args=CommandLine.arguments
        let folder=URL(fileURLWithPath:args[1]),out=URL(fileURLWithPath:args[3])
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let recording=try JSONDecoder().decode(StadiumSceneRecording.self,from:Data(contentsOf:folder.appendingPathComponent("scene.json")))
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:folder.appendingPathComponent("foreground.mp4")))
        generator.appliesPreferredTrackTransform=true
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let cg=try await generator.image(at:CMTime(seconds:4.133333,preferredTimescale:60000)).image
        let renderer=try StadiumPreviewRenderer(library:args[2]),ci=CIContext(mtlDevice:renderer.device)
        let source=try ForegroundMaskProcessor.buffer(width:cg.width,height:cg.height,format:kCVPixelFormatType_32BGRA)
        ci.render(CIImage(cgImage:cg),to:source)
        let target=try ForegroundMaskProcessor.buffer(width:1080,height:1920,format:kCVPixelFormatType_32BGRA)
        let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
        for degrees in [0,30,90,180,270,360] {
            var rig=recording.sample(at:4.133333);rig.look.x=Float(degrees) * .pi/180
            let start=Date()
            try renderer.render(source:source,mask:source,output:target,camera:rig,time:4.133333,scene:true,packed:true,
                sourceRect:recording.sourceRect!,environment:.indoorArena,refined:recording.matteVersion == 2)
            print("View \(degrees): \(Date().timeIntervalSince(start)*1000) ms including CPU submission")
            try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:target),to:out.appendingPathComponent("view-\(degrees).png"),format:.RGBA8,colorSpace:colorSpace)
        }
        let empty=try ForegroundMaskProcessor.buffer(width:8,height:8,format:kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(empty,[]);memset(CVPixelBufferGetBaseAddress(empty)!,0,CVPixelBufferGetBytesPerRow(empty)*8);CVPixelBufferUnlockBaseAddress(empty,[])
        let hero=try ForegroundMaskProcessor.buffer(width:1536,height:1024,format:kCVPixelFormatType_32BGRA)
        var room=SceneCameraRig(aspect:1.5,subjectHeight:0.40,ground:SIMD2(0.5,0.83))
        room.movement=0;room.horizon=0.61;room.verticalFOV=65 * .pi/180
        for (name,yaw) in [("arena",Float(0)),("arena-reverse",Float.pi),("arena-side",Float.pi/2)] {
            room.look.x=yaw
            try renderer.render(source:empty,mask:empty,output:hero,camera:room,time:0,scene:true,environment:.indoorArena)
            try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:hero),to:out.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:colorSpace)
        }
    }
}
