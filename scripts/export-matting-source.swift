// Upright, native-detail SDR crop for external local model comparisons.
// SOURCE SCENE.json OUTPUT.mp4
import AVFoundation
import CoreImage
import Foundation
import Metal

@main struct ExportMattingSource {
    static func main() async throws {
        let a=CommandLine.arguments,asset=AVURLAsset(url:URL(fileURLWithPath:a[1]))
        let recording=try JSONDecoder().decode(StadiumSceneRecording.self,from:Data(contentsOf:URL(fileURLWithPath:a[2])))
        let rect=recording.sourceRect!,duration=try await asset.load(.duration),track=try await asset.loadTracks(withMediaType:.video)[0]
        let composition=try await EffectVideoGeometry.composition(track:track,duration:duration,shortEdge:2160)
        composition.frameDuration=CMTime(value:1,timescale:30)
        let size=composition.renderSize
        let roi=CGRect(x:rect.minX*size.width,y:(1-rect.maxY)*size.height,width:rect.width*size.width,height:rect.height*size.height).integral
        let outSize=CGSize(width:Int(roi.width)/2*2,height:Int(roi.height)/2*2)
        let ci=CIContext(mtlDevice:MTLCreateSystemDefaultDevice()!)
        let writer=try PreviewMovie(url:URL(fileURLWithPath:a[3]),size:outSize)
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderVideoCompositionOutput(videoTracks:[track],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.videoComposition=composition;reader.add(output);guard reader.startReading() else {throw reader.error!}
        var count=0
        while let sample=output.copyNextSampleBuffer() {
            let buffer=try autoreleasepool { () -> CVPixelBuffer in
                let source=CIImage(cvPixelBuffer:CMSampleBufferGetImageBuffer(sample)!).cropped(to:roi)
                    .transformed(by:CGAffineTransform(translationX:-roi.minX,y:-roi.minY))
                    .transformed(by:CGAffineTransform(scaleX:outSize.width/roi.width,y:outSize.height/roi.height))
                let b=try writer.buffer();ci.render(source,to:b);return b
            }
            try await writer.append(buffer,time:CMSampleBufferGetPresentationTimeStamp(sample));count+=1
        }
        guard reader.status == .completed else {throw reader.error!}
        try await writer.finish(duration:duration)
        print("\(count) frames \(outSize)")
    }
}
