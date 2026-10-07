// Native macOS study: source + track JSON + Metal library + output folder + start + duration.
// Compiled with the reusable Environments types and EffectVideoGeometry.swift.
import AVFoundation
import CoreImage
import Foundation
import Vision

@main struct ForegroundReview {
    final class Movie {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        init(url: URL, size: CGSize) throws {
            try? FileManager.default.removeItem(at: url)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey:AVVideoCodecType.h264,
                AVVideoWidthKey:Int(size.width), AVVideoHeightKey:Int(size.height),
                AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:7_000_000]])
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:Int(size.width),kCVPixelBufferHeightKey as String:Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true])
            writer.add(input)
            guard writer.startWriting() else {throw writer.error!}
            writer.startSession(atSourceTime: .zero)
        }
        func buffer() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&buffer)==kCVReturnSuccess,
                  let buffer else {throw ForegroundMaskProcessor.Failure.allocation}
            return buffer
        }
        func append(_ buffer: CVPixelBuffer, time: CMTime) async throws {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {throw writer.error ?? ForegroundMaskProcessor.Failure.allocation}
                try await Task.sleep(for:.milliseconds(2))
            }
            guard adaptor.append(buffer,withPresentationTime:time) else {throw writer.error!}
        }
        func finish(duration: CMTime) async throws {
            input.markAsFinished();writer.endSession(atSourceTime:duration);await writer.finishWriting()
            guard writer.status == .completed else {throw writer.error!}
        }
    }
    static func main() async throws {
        let args=CommandLine.arguments
        let sourceURL=URL(fileURLWithPath:args[1]), folder=URL(fileURLWithPath:args[4])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let begin=Double(args[5])!, requested=Double(args[6])!
        let asset=AVURLAsset(url:sourceURL), tracks=try await asset.loadTracks(withMediaType:.video)
        let duration=try await asset.load(.duration), end=min(duration.seconds,begin+requested)
        let composition=try await EffectVideoGeometry.composition(track:tracks[0],duration:duration,shortEdge:720)
        // This study uses 30 fps; final shipping export must retain source cadence.
        composition.frameDuration=CMTime(value:1,timescale:30)
        let size=composition.renderSize
        let json=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [String:Any]
        let rows=(json["track"] as! [[String:Double]]).sorted {$0["time"]! < $1["time"]!}
        func ball(at time:Double) -> CGRect? {
            guard let b=rows.min(by:{abs($0["time"]!-time)<abs($1["time"]!-time)}), abs(b["time"]!-time)<0.025,
                  b["score"]!>=0.05 else {return nil}
            return CGRect(x:b["x"]!-b["width"]!/2,y:b["y"]!-b["height"]!/2,width:b["width"]!,height:b["height"]!)
        }
        let gpu=try StadiumPreviewRenderer(library:args[3])
        let ci=CIContext(mtlDevice:gpu.device,options:[.cacheIntermediates:false])
        let calibration = try await StadiumSceneCalibration.make(asset:asset,start:begin,duration:end-begin,size:size)
        let crop=calibration.crop, rig=calibration.camera
        let groundX=Double(rig.ground.x), groundY=Double(rig.ground.y), personHeight=Double(rig.subjectHeight)
        print("Crop \(crop); camera distance \(rig.distance), eye height \(rig.eyeHeight)")
        let balanced=ForegroundMaskProcessor(quality:.balanced,sourceCrop:crop,context:ci)
        let accurate=ForegroundMaskProcessor(quality:.accurate,sourceCrop:crop,context:ci)
        let names=["balanced","accurate","camera","mask","locked","source"]
        let movies=try names.map {try Movie(url:folder.appendingPathComponent($0+"-silent.mp4"),size:size)}
        let maskBuffer=try ForegroundMaskProcessor.buffer(width:Int(size.width),height:Int(size.height),format:kCVPixelFormatType_32BGRA)
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[tracks[0]],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String:true])
        output.videoComposition=composition;output.alwaysCopiesSampleData=false
        reader.add(output);reader.timeRange=CMTimeRange(start:CMTime(seconds:begin,preferredTimescale:600),end:CMTime(seconds:end,preferredTimescale:600))
        guard reader.startReading() else {throw reader.error!}
        var count=0, timings:[String:[Double]]=["balanced":[],"accurate":[]]
        var contacts:[[String:Double]]=[]
        var contactTracker=FootContactTracker()
        let wallStart=Date()
        while let sample=output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let stamp=CMSampleBufferGetPresentationTimeStamp(sample), time=stamp.seconds
            let relative=CMTimeSubtract(stamp,CMTime(seconds:begin,preferredTimescale:600))
            guard relative.seconds>=0,let pixels=CMSampleBufferGetImageBuffer(sample) else {continue}
            let products: [CVPixelBuffer] = try autoreleasepool {
                var results:[CVPixelBuffer]=[]
                var finalMatte:ForegroundMatte?
                for (i,processor) in [balanced,accurate].enumerated() {
                    let start=Date(), matte=try processor.process(pixels,at:time,ball:ball(at:time))
                    timings[names[i],default:[]].append(Date().timeIntervalSince(start));finalMatte=matte
                    ci.render(matte.image(size:size),to:maskBuffer)
                    let target=try movies[i].buffer()
                    try gpu.render(source:pixels,mask:maskBuffer,output:target,camera:rig,time:time-begin,scene:false)
                    results.append(target)
                }
                var frameRig=rig
                if let matte=finalMatte {
                    frameRig.contact=contactTracker.update(VisibleFootContact.measure(person:matte.person,rect:matte.personRect),at:time)
                }
                if let contact=frameRig.contact {
                    contacts.append(["time":time-begin,"x":Double(contact.point.x),"y":Double(contact.point.y),
                        "width":Double(contact.width),"depth":Double(frameRig.subjectDistance),"confidence":Double(contact.confidence)])
                }
                let scene=try movies[2].buffer()
                try gpu.render(source:pixels,mask:maskBuffer,output:scene,camera:frameRig,time:time-begin,scene:true)
                results.append(scene)
                let mask=try movies[3].buffer();ci.render(finalMatte!.image(size:size),to:mask);results.append(mask)
                var fixedRig=frameRig;fixedRig.movement=0
                let locked=try movies[4].buffer()
                try gpu.render(source:pixels,mask:maskBuffer,output:locked,camera:fixedRig,time:time-begin,scene:true)
                results.append(locked)
                let original=try movies[5].buffer();ci.render(CIImage(cvPixelBuffer:pixels),to:original);results.append(original)
                if count%30==0 {
                    try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:pixels),to:folder.appendingPathComponent("source-\(count/30).png"),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
                    for i in [1,2,3] {
                        try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:results[i]),
                            to:folder.appendingPathComponent("\(names[i])-\(count/30).png"),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
                    }
                    print("\(count) frames · source \(String(format:"%.2f",time))s")
                }
                return results
            }
            for i in movies.indices {try await movies[i].append(products[i],time:relative)}
            count+=1
        }
        guard reader.status == .completed else {throw reader.error ?? ForegroundMaskProcessor.Failure.invalidFrame}
        for movie in movies {try await movie.finish(duration:CMTime(seconds:end-begin,preferredTimescale:600))}
        let stats=timings.mapValues {values -> [String:Double] in
            let sorted=values.sorted();return ["mean_ms":values.reduce(0,+)/Double(values.count)*1000,
                "p95_ms":sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]*1000]
        }
        let report:[String:Any]=["source":sourceURL.path,"start":begin,"duration":end-begin,"frames":count,"fps":30,
            "size":[Int(size.width),Int(size.height)],"crop":[crop.minX,crop.minY,crop.width,crop.height],
            "camera":["groundX":groundX,"groundY":groundY,"personHeight":personHeight,"distance":Double(rig.distance),"eyeHeight":Double(rig.eyeHeight)],
            "segmentation":stats,"wall_seconds":Date().timeIntervalSince(wallStart),
            "notes":"Mac GPU study, not an iPhone performance measurement. Ball mask uses local edge refinement. Camera uses a 2D subject plane and small 3D movement; source motion is not solved yet."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("report.json"))
        try JSONSerialization.data(withJSONObject:contacts,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("contacts.json"))
        print("COMPLETE \(count) frames in \(Date().timeIntervalSince(wallStart))s")
    }
}
