// CACHE_FOLDER OUTPUT.json. Inspect decoded soles against the saved floor.
import AVFoundation
import Foundation

@main struct AuditGroundContact {
    static func main() async throws {
        let a=CommandLine.arguments,folder=URL(fileURLWithPath:a[1])
        let recording=try JSONDecoder().decode(StadiumSceneRecording.self,from:Data(contentsOf:folder.appendingPathComponent("scene.json")))
        let lossless=try recording.losslessAlpha == true ? LosslessAlphaCache.Reader(folder:folder):nil
        let rect=recording.sourceRect!,asset=AVURLAsset(url:folder.appendingPathComponent("foreground.mp4"))
        let original=AVURLAsset(url:folder.appendingPathComponent("original.mp4"))
        let originalTrack=try await original.loadTracks(withMediaType:.video)[0]
        let previewHeight=Float(try await originalTrack.load(.naturalSize).height)
        let track=try await asset.loadTracks(withMediaType:.video)[0],reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);guard reader.startReading() else {throw reader.error!}
        var rows:[[String:Any]]=[]
        while let sample=output.copyNextSampleBuffer() {
            try autoreleasepool {
                let p=CMSampleBufferGetImageBuffer(sample)!,w=CVPixelBufferGetWidth(p)/2,h=CVPixelBufferGetHeight(p)
                let time=CMSampleBufferGetPresentationTimeStamp(sample).seconds,camera=recording.sample(at:time)
                let alpha:CVPixelBuffer
                if let lossless {alpha=try lossless.frame(at:time)}
                else {
                alpha=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_OneComponent8)
                CVPixelBufferLockBaseAddress(p,.readOnly);CVPixelBufferLockBaseAddress(alpha,[])
                let src=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:UInt8.self),dst=CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to:UInt8.self)
                for y in 0..<h {for x in 0..<w {dst[y*CVPixelBufferGetBytesPerRow(alpha)+x]=src[y*CVPixelBufferGetBytesPerRow(p)+(w+x)*4]}}
                CVPixelBufferUnlockBaseAddress(alpha,[]);CVPixelBufferUnlockBaseAddress(p,.readOnly)
                }
                var row:[String:Any]=["frame":rows.count,"time":time]
                if let sole=VisibleFootContact.measure(person:alpha,rect:rect),let contact=camera.contact {
                    row["soleY"]=sole.point.y;row["anchorY"]=contact.point.y
                    row["confidence"]=contact.confidence
                    let world=camera.worldPoint(sourceUV:sole.point)
                    row["belowFloorCM"] = -world.y*100
                    row["solePreviewPixelDelta"]=(sole.point.y-contact.point.y)*previewHeight
                    row["belowFloorRenderedPixels"]=(camera.project(world,at:time).y-camera.project(SIMD3(world.x,0,world.z),at:time).y)*previewHeight
                }
                rows.append(row)
            }
        }
        let values=rows.compactMap {$0["belowFloorCM"] as? Float}.sorted()
        let report:[String:Any]=["frames":rows.count,"framesBelowFloorOver1CM":values.filter {$0>1}.count,
            "maxBelowFloorCM":values.last ?? 0,"rows":rows,
            "note":"Visible alpha >=64/255. Centimeters are virtual units assuming a 1.75m subject, not physical measurements. Rendered pixel displacement uses saved default framing." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:a[2]))
        print("Frames \(rows.count), >1cm below floor \(values.filter {$0>1}.count), max \(values.last ?? 0) cm")
    }
}
