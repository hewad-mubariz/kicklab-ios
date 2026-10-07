// Source + detector JSON + output directory. Compare actual sequential masks,
// not independently initialized still-image segmentation at selected times.
import AVFoundation
import AppKit
import CoreImage
import Foundation
import Metal

@main struct ReviewBallCutout {
 static func main() async throws {
    let args=CommandLine.arguments,asset=AVURLAsset(url:URL(fileURLWithPath:args[1]))
    let folder=URL(fileURLWithPath:args[3]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let json=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [String:Any]
    let rows=(json["track"] as! [[String:Double]]).sorted {$0["time"]!<$1["time"]!}
    let duration=try await asset.load(.duration),track=try await asset.loadTracks(withMediaType:.video)[0]
    let seconds=min(12,duration.seconds)
    let composition=try await EffectVideoGeometry.composition(track:track,duration:duration,shortEdge:2160)
    composition.frameDuration=CMTime(value:1,timescale:30)
    let size=composition.renderSize,ci=CIContext(mtlDevice:MTLCreateSystemDefaultDevice()!,options:[.cacheIntermediates:false])
    let calibration=try await StadiumSceneCalibration.make(asset:asset,duration:seconds,size:CGSize(width:1080,height:1920))
    let processor=DetailedForegroundMaskProcessor(sourceCrop:calibration.crop,context:ci)
    var reviewRegion=calibration.crop
    for b in rows {reviewRegion=reviewRegion.union(CGRect(x:b["x"]!-b["width"]!,y:b["y"]!-b["height"]!,width:b["width"]!*2,height:b["height"]!*2))}
    reviewRegion=reviewRegion.intersection(CGRect(x:0,y:0,width:1,height:1))
    let reader=try AVAssetReader(asset:asset),output=AVAssetReaderVideoCompositionOutput(videoTracks:[track],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    output.videoComposition=composition;output.alwaysCopiesSampleData=false;reader.add(output)
    reader.timeRange=CMTimeRange(start:.zero,duration:CMTime(seconds:seconds,preferredTimescale:60000));guard reader.startReading() else {throw reader.error!}
    var log:[[String:Any]]=[],index=0
    let bg=CIImage(color:CIColor(red:0.12,green:0.04,blue:0.22)).cropped(to:CGRect(origin:.zero,size:size))
    func stats(_ b:CVPixelBuffer)->[String:Int] {
        CVPixelBufferLockBaseAddress(b,.readOnly);defer {CVPixelBufferUnlockBaseAddress(b,.readOnly)}
        let w=CVPixelBufferGetWidth(b),h=CVPixelBufferGetHeight(b),row=CVPixelBufferGetBytesPerRow(b),p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self)
        var count=0,minX=w,minY=h,maxX=0,maxY=0
        for y in 0..<h {for x in 0..<w where p[y*row+x]>64 {count+=1;minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)}}
        return ["area":count,"width":w,"height":h,"left":minX,"top":minY,"right":maxX,"bottom":maxY]
    }
    func rect(_ b:CGRect?)->[Double]? {b.map {[Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)]}}
    while let sample=output.copyNextSampleBuffer() {
      try autoreleasepool {
        let time=CMSampleBufferGetPresentationTimeStamp(sample).seconds,pixels=CMSampleBufferGetImageBuffer(sample)!
        let near=rows.min {abs($0["time"]!-time)<abs($1["time"]!-time)}
        let hint=near.flatMap {abs($0["time"]!-time)<0.025 ? CGRect(x:$0["x"]!-$0["width"]!/2,y:$0["y"]!-$0["height"]!/2,width:$0["width"]!,height:$0["height"]!):nil}
        let matte=try processor.process(pixels,at:time,ball:hint,ballConfidence:hint == nil ? 0:near!["score"]!)
        var row:[String:Any]=["frame":index,"time":time,"score":near?["score"] ?? 0,"person":stats(matte.person),"method":processor.lastBallMethod,"quality":processor.lastBallQuality]
        row["hint"]=rect(hint);row["tracked"]=rect(processor.lastBallBounds);row["ballRect"]=rect(matte.ballRect)
        if let ball=matte.ball {row["ball"]=stats(ball)}
        let source=CIImage(cvPixelBuffer:pixels),mask=matte.image(size:size)
        let cut=source.applyingFilter("CIBlendWithMask",parameters:[kCIInputMaskImageKey:mask,kCIInputBackgroundImageKey:bg])
        let region=reviewRegion
        let roi=CGRect(x:region.minX*size.width,y:(1-region.maxY)*size.height,width:region.width*size.width,height:region.height*size.height).integral
        let scale=560/roi.height
        let images=[source,cut].map {$0.cropped(to:roi).transformed(by:CGAffineTransform(translationX:-roi.minX,y:-roi.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))}
        let w=Int(roi.width*scale),h=560
        let canvas=CGContext(data:nil,width:w*2,height:h+24,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(NSColor.black.cgColor);canvas.fill(CGRect(x:0,y:0,width:w*2,height:h+24))
        for (i,img) in images.enumerated() {canvas.draw(ci.createCGImage(img,from:img.extent)!,in:CGRect(x:i*w,y:0,width:w,height:h))}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:canvas,flipped:false)
        (String(format:"%03d %.3fs · %@",index,time,processor.lastBallMethod) as NSString).draw(at:NSPoint(x:6,y:h+4),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        let bitmap=NSBitmapImageRep(cgImage:canvas.makeImage()!)
        try bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.86])!.write(to:folder.appendingPathComponent(String(format:"frame-%03d.jpg",index)))
        log.append(row);index+=1
      }
    }
    guard reader.status == .completed else {throw reader.error!}
    try JSONSerialization.data(withJSONObject:log,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("frames.json"))
    print("\(index) frames · missing ball \(log.filter {$0["ball"] == nil}.count) · \(folder.path)")
 }
}
