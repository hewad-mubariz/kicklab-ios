// Render a prepared packed foreground at several views without running Vision.
import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal

@main struct ReviewStadiumCamera {
 static func main() async throws {
    let a=CommandLine.arguments,folder=URL(fileURLWithPath:a[1]),out=URL(fileURLWithPath:a[3])
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let recording=try JSONDecoder().decode(StadiumSceneRecording.self,from:Data(contentsOf:folder.appendingPathComponent("scene.json")))
    let generator=AVAssetImageGenerator(asset:AVURLAsset(url:folder.appendingPathComponent("foreground.mp4")))
    generator.appliesPreferredTrackTransform=true;generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    let time=a.count>4 ? Double(a[4])! : 2.0
    let cg=try await generator.image(at:CMTime(seconds:time,preferredTimescale:60000)).image
    let renderer=try StadiumPreviewRenderer(library:a[2]),ci=CIContext(mtlDevice:renderer.device)
    let source=try ForegroundMaskProcessor.buffer(width:cg.width,height:cg.height,format:kCVPixelFormatType_32BGRA)
    ci.render(CIImage(cgImage:cg),to:source)
    let output=try ForegroundMaskProcessor.buffer(width:1080,height:Int(1080/recording.camera.aspect),format:kCVPixelFormatType_32BGRA)
    var cache:CVMetalTextureCache?;CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,renderer.device,nil,&cache)
    func texture(_ b:CVPixelBuffer) -> (CVMetalTexture,MTLTexture) {
        var ref:CVMetalTexture?;CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache!,b,nil,.bgra8Unorm,CVPixelBufferGetWidth(b),CVPixelBufferGetHeight(b),0,&ref)
        return (ref!,CVMetalTextureGetTexture(ref!)!)
    }
    let (sourceRef,sourceTexture)=texture(source),(outputRef,target)=texture(output)
    for degrees in [0,45,90,180,270,360] {
        var camera=recording.sample(at:time);camera.look.x=Float(degrees)*Float.pi/180
        let command=renderer.queue.makeCommandBuffer()!
        try renderer.encode(source:sourceTexture,mask:sourceTexture,target:target,camera:camera,time:time,packed:true,sourceRect:recording.sourceRect ?? CGRect(x:0,y:0,width:1,height:1),refined:recording.matteVersion == 2,command:command)
        command.commit();command.waitUntilCompleted();if let error=command.error {throw error}
        try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:output),to:out.appendingPathComponent("view-\(degrees).png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
    }
    withExtendedLifetime((sourceRef,outputRef)) {}
 }
}
