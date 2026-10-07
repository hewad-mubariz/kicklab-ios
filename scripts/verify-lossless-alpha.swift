// PREPARED_FOLDER STAGES_FOLDER OUTPUT.json. Verify decoded color timestamps
// and every saved numeric alpha value; replay backward to exercise seeking.
import AVFoundation
import CoreVideo
import Foundation
import ImageIO

@main struct VerifyLosslessAlpha {
    static func main() async throws {
        let a=CommandLine.arguments,folder=URL(fileURLWithPath:a[1]),stages=URL(fileURLWithPath:a[2])
        let cache=try LosslessAlphaCache.Reader(folder:folder)
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:stages.appendingPathComponent("stages.json"))) as! [[String:Any]]
        var compared=0,values=0,mismatches=0
        for entry in manifest.reversed() where entry["stage"] as? String == "refined-alpha" {
            let alpha=try cache.frame(at:entry["time"] as! Double)
            let source=CGImageSourceCreateWithURL(stages.appendingPathComponent(entry["file"] as! String) as CFURL,nil)!
            let image=CGImageSourceCreateImageAtIndex(source,0,nil)!,data=image.dataProvider!.data!
            guard image.bitsPerPixel==8,image.width==CVPixelBufferGetWidth(alpha),image.height==CVPixelBufferGetHeight(alpha) else {throw ForegroundMaskProcessor.Failure.invalidFrame}
            let expected=CFDataGetBytePtr(data)!
            CVPixelBufferLockBaseAddress(alpha,.readOnly)
            let actual=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(alpha)
            for y in 0..<image.height {for x in 0..<image.width {
                values+=1;if actual[y*row+x] != expected[y*image.bytesPerRow+x] {mismatches+=1}
            }}
            CVPixelBufferUnlockBaseAddress(alpha,.readOnly);compared+=1
        }
        let asset=AVURLAsset(url:folder.appendingPathComponent("foreground.mp4")),track=try await asset.loadTracks(withMediaType:.video)[0]
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);guard reader.startReading() else {throw reader.error!}
        var frames=0
        while let sample=output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else {throw ForegroundMaskProcessor.Failure.invalidFrame}
            _=try cache.frame(at:CMSampleBufferGetPresentationTimeStamp(sample).seconds);frames+=1
        }
        guard frames==cache.frameCount,mismatches==0,compared>0,reader.status == .completed else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        let report:[String:Any]=["videoFrames":frames,"alphaFrames":cache.frameCount,"comparedFrames":compared,"comparedPixels":values,"mismatches":mismatches]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:a[3]))
        print(report)
    }
}
