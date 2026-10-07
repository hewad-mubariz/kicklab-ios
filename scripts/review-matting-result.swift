// Render old/new caches using the SAME camera and scene, in timestamp order.
// OLD_FOLDER NEW_FOLDER METALLIB OUTPUT_FOLDER
import AVFoundation
import CoreImage
import Foundation

@main struct ReviewMattingResult {
    static func main() async throws {
        let a=CommandLine.arguments,old=URL(fileURLWithPath:a[1]),new=URL(fileURLWithPath:a[2]),out=URL(fileURLWithPath:a[4])
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let recordings=try [old,new].map {try JSONDecoder().decode(StadiumSceneRecording.self,from:Data(contentsOf:$0.appendingPathComponent("scene.json")))}
        let alphas=try zip([old,new],recordings).map {folder,recording in try recording.losslessAlpha == true ? LosslessAlphaCache.Reader(folder:folder):nil}
        let assets=[old,new].map {AVURLAsset(url:$0.appendingPathComponent("foreground.mp4"))}
        let renderer=try StadiumPreviewRenderer(library:a[3]),ci=CIContext(mtlDevice:renderer.device)
        var readers:[AVAssetReader]=[],outputs:[AVAssetReaderTrackOutput]=[]
        for asset in assets {
            let track=try await asset.loadTracks(withMediaType:.video)[0],reader=try AVAssetReader(asset:asset)
            let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData=false;reader.add(output)
            guard reader.startReading() else {throw reader.error!};readers.append(reader);outputs.append(output)
        }
        let size=CGSize(width:1080,height:1920),wide=CGSize(width:2160,height:1920)
        let movie=try PreviewMovie(url:out.appendingPathComponent("comparison-silent.mp4"),size:wide)
        let final=try PreviewMovie(url:out.appendingPathComponent("indoor-silent.mp4"),size:size)
        var count=0
        while let current=outputs[1].copyNextSampleBuffer() {
            guard let prior=outputs[0].copyNextSampleBuffer() else {throw ForegroundMaskProcessor.Failure.invalidFrame}
            let stamp=CMSampleBufferGetPresentationTimeStamp(current)
            guard abs(stamp.seconds-CMSampleBufferGetPresentationTimeStamp(prior).seconds)<0.001 else {throw ForegroundMaskProcessor.Failure.invalidFrame}
            let products=try autoreleasepool { () -> (CVPixelBuffer,CVPixelBuffer) in
                var images:[CIImage]=[],newPixels:CVPixelBuffer?
                for (i,sample) in [prior,current].enumerated() {
                    let pixels=CMSampleBufferGetImageBuffer(sample)!,target=try final.buffer()
                    var camera=recordings[1].sample(at:stamp.seconds);camera.followRecordedCamera=false
                    try renderer.render(source:pixels,mask:try alphas[i]?.frame(at:stamp.seconds) ?? pixels,output:target,camera:camera,time:stamp.seconds,scene:true,packed:true,
                        sourceRect:recordings[i].sourceRect!,environment:.indoorArena,refined:recordings[i].matteVersion == 2,separateAlpha:alphas[i] != nil)
                    images.append(CIImage(cvPixelBuffer:target));if i==1 {newPixels=target}
                }
                let canvas=try movie.buffer()
                ci.render(images[1].transformed(by:CGAffineTransform(translationX:size.width,y:0)).composited(over:images[0]),to:canvas)
                if count%15==0 || [124,125,126].contains(count) {
                    try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:canvas),to:out.appendingPathComponent(String(format:"%03d.png",count)),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                }
                return (canvas,newPixels!)
            }
            try await movie.append(products.0,time:stamp);try await final.append(products.1,time:stamp);count+=1
        }
        guard readers.allSatisfy({$0.status == .completed || $0.status == .reading}),outputs[0].copyNextSampleBuffer()==nil else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        let duration=try await assets[1].load(.duration)
        try await movie.finish(duration:duration);try await final.finish(duration:duration)
        let audio=try await assets[1].loadTracks(withMediaType:.audio)
        for name in ["comparison","indoor"] {
            try await StadiumPreviewPreparer.preserveAudio(silent:out.appendingPathComponent(name+"-silent.mp4"),destination:out.appendingPathComponent(name+".mp4"),audio:audio,duration:duration)
        }
        print("\(count) frames; left=\(old.path), right=\(new.path); identical new camera")
    }
}
