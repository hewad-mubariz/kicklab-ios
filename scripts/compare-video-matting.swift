// Consecutive-frame, local comparison. RVM is evaluation-only, outside the app.
// SOURCE TRACK.json OUTPUT RVM.mlmodelc [SECONDS]
import AVFoundation
import CoreImage
import CoreML
import Foundation
import Metal
import Vision

@main struct VideoMattingComparison {
    static func main() async throws {
        let args=CommandLine.arguments, folder=URL(fileURLWithPath:args[3])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let asset=AVURLAsset(url:URL(fileURLWithPath:args[1]))
        let duration=try await asset.load(.duration), seconds=min(duration.seconds,Double(args.last!) ?? 12)
        let track=try await asset.loadTracks(withMediaType:.video)[0]
        let composition=try await EffectVideoGeometry.composition(track:track,duration:duration,shortEdge:2160)
        composition.frameDuration=CMTime(value:1,timescale:30)
        let size=composition.renderSize
        let ci=CIContext(mtlDevice:MTLCreateSystemDefaultDevice()!,options:[.cacheIntermediates:false])
        let calibration=try await StadiumSceneCalibration.make(asset:asset,duration:seconds,size:CGSize(width:1080,height:1920))
        // Full source width removes lateral crop truncation from candidate methods.
        let safeCrop=CGRect(x:0,y:max(0,calibration.crop.minY-0.04),width:1,height:min(1,calibration.crop.maxY+0.04)-max(0,calibration.crop.minY-0.04))
        let nativeROI=CGRect(x:0,y:(1-safeCrop.maxY)*size.height,width:size.width,height:safeCrop.height*size.height).integral
        let outSize=CGSize(width:720,height:Double(Int(nativeROI.height/nativeROI.width*720)/2*2))
        let baseline=DetailedForegroundMaskProcessor(sourceCrop:calibration.crop,context:ci)
        let wide=DetailedForegroundMaskProcessor(sourceCrop:safeCrop,context:ci)
        let accurate=VNGeneratePersonSegmentationRequest();accurate.qualityLevel = .accurate
        accurate.outputPixelFormat=kCVPixelFormatType_OneComponent8
        let balanced=VNGeneratePersonSegmentationRequest();balanced.qualityLevel = .balanced
        balanced.outputPixelFormat=kCVPixelFormatType_OneComponent8
        let model=try MLModel(contentsOf:URL(fileURLWithPath:args[4]))
        print(model.modelDescription)
        let constraint=model.modelDescription.inputDescriptionsByName["src"]!.imageConstraint!
        let modelSize=CGSize(width:constraint.pixelsWide,height:constraint.pixelsHigh)
        let input=try ForegroundMaskProcessor.buffer(width:Int(nativeROI.width),height:Int(nativeROI.height),format:kCVPixelFormatType_32BGRA)
        let rvmInput=try ForegroundMaskProcessor.buffer(width:Int(modelSize.width),height:Int(modelSize.height),format:kCVPixelFormatType_32BGRA)
        var recurrent:[String:MLFeatureValue]=[:]
        let names=["source","baseline","wide-lift","accurate-video","balanced-video","rvm"]
        let movies=try names.map {try PreviewMovie(url:folder.appendingPathComponent($0+".mp4"),size:outSize)}
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[track],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.videoComposition=composition;output.alwaysCopiesSampleData=false;reader.add(output)
        reader.timeRange=CMTimeRange(start:.zero,duration:CMTime(seconds:seconds,preferredTimescale:60000))
        guard reader.startReading() else {throw reader.error!}
        let trackJSON=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [String:Any]
        let balls=trackJSON["track"] as! [[String:Double]]
        let bounds=CGRect(origin:.zero,size:outSize)
        let bg=CIImage(color:CIColor(red:0.28,green:0.04,blue:0.35)).cropped(to:bounds)
        func scaled(_ image:CIImage)->CIImage {
            image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
                .transformed(by:CGAffineTransform(scaleX:outSize.width/image.extent.width,y:outSize.height/image.extent.height))
        }
        var frames:[[String:Any]]=[],index=0
        let start=Date()
        print("CROP \(calibration.crop) SAFE \(safeCrop) OUTPUT \(outSize)")
        while let sample=output.copyNextSampleBuffer() {
            let stamp=CMSampleBufferGetPresentationTimeStamp(sample), time=stamp.seconds
            let products:[CVPixelBuffer]=try autoreleasepool {
                let pixels=CMSampleBufferGetImageBuffer(sample)!, source=CIImage(cvPixelBuffer:pixels)
                let cropped=source.cropped(to:nativeROI).transformed(by:CGAffineTransform(translationX:-nativeROI.minX,y:-nativeROI.minY))
                ci.render(cropped,to:input)
                let color=scaled(cropped)
                var row:[String:Any]=["frame":index,"time":time], masks:[CIImage]=[], colors:[CIImage]=[]
                let nearest=balls.min {abs($0["time"]!-time)<abs($1["time"]!-time)}
                let hint=nearest.flatMap {abs($0["time"]!-time)<0.025 ? CGRect(x:$0["x"]!-$0["width"]!/2,y:$0["y"]!-$0["height"]!/2,width:$0["width"]!,height:$0["height"]!):nil}
                for (name,processor) in [("baseline",baseline),("wide-lift",wide)] {
                    let then=Date(), matte=try processor.process(pixels,at:time,ball:hint,ballConfidence:nearest?["score"] ?? 0)
                    row[name+"Ms"]=Date().timeIntervalSince(then)*1000
                    masks.append(scaled(matte.image(size:size).cropped(to:nativeROI)));colors.append(color)
                }
                for (name,request) in [("accurate-video",accurate),("balanced-video",balanced)] {
                    let then=Date();try VNImageRequestHandler(cvPixelBuffer:input,orientation:.up).perform([request])
                    let raw=CIImage(cvPixelBuffer:request.results!.first!.pixelBuffer,options:[.colorSpace:NSNull()])
                    masks.append(scaled(raw));colors.append(color)
                    row[name+"Ms"]=Date().timeIntervalSince(then)*1000
                }
                let then=Date(), scale=min(modelSize.width/cropped.extent.width,modelSize.height/cropped.extent.height)
                let fitted=CGSize(width:cropped.extent.width*scale,height:cropped.extent.height*scale)
                let offset=CGPoint(x:(modelSize.width-fitted.width)/2,y:(modelSize.height-fitted.height)/2)
                let fittedRect=CGRect(origin:offset,size:fitted)
                let letterbox=cropped.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    .transformed(by:CGAffineTransform(translationX:offset.x,y:offset.y))
                    .composited(over:CIImage(color:.black).cropped(to:CGRect(origin:.zero,size:modelSize)))
                ci.render(letterbox,to:rvmInput)
                var features=recurrent;features["src"]=MLFeatureValue(pixelBuffer:rvmInput)
                let prediction=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:features))
                for n in 1...4 {recurrent["r\(n)i"]=prediction.featureValue(for:"r\(n)o")!}
                let alpha=CIImage(cvPixelBuffer:prediction.featureValue(for:"pha")!.imageBufferValue!,options:[.colorSpace:NSNull()])
                let foreground=CIImage(cvPixelBuffer:prediction.featureValue(for:"fgr")!.imageBufferValue!)
                masks.append(scaled(alpha.cropped(to:fittedRect)));colors.append(scaled(foreground.cropped(to:fittedRect)))
                row["rvmMs"]=Date().timeIntervalSince(then)*1000
                var images=[color]
                for i in masks.indices {
                    images.append(colors[i].applyingFilter("CIBlendWithMask",parameters:[kCIInputMaskImageKey:masks[i],kCIInputBackgroundImageKey:bg]))
                }
                if index%15==0 || [124,125,126].contains(index) {
                    for (i,img) in images.enumerated() {
                        try ci.writePNGRepresentation(of:img,to:folder.appendingPathComponent(String(format:"%03d-",index)+names[i]+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                    }
                    for (i,mask) in masks.enumerated() {
                        let numeric=try ForegroundMaskProcessor.buffer(width:Int(outSize.width),height:Int(outSize.height),format:kCVPixelFormatType_32BGRA)
                        ci.render(mask,to:numeric,bounds:bounds,colorSpace:nil)
                        try ci.writePNGRepresentation(of:CIImage(cvPixelBuffer:numeric),to:folder.appendingPathComponent(String(format:"%03d-",index)+names[i+1]+"-mask.png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                    }
                }
                frames.append(row)
                return try images.enumerated().map {i,img in let b=try movies[i].buffer();ci.render(img,to:b);return b}
            }
            for i in movies.indices {try await movies[i].append(products[i],time:stamp)}
            index+=1
            if index%30==0 {print("FRAME \(index) elapsed \(Date().timeIntervalSince(start))")}
        }
        guard reader.status == .completed else {throw reader.error!}
        for movie in movies {try await movie.finish(duration:CMTime(seconds:seconds,preferredTimescale:60000))}
        let report:[String:Any]=["frames":frames,"crop":[calibration.crop.minX,calibration.crop.minY,calibration.crop.width,calibration.crop.height],"safeCrop":[safeCrop.minX,safeCrop.minY,safeCrop.width,safeCrop.height],"source":args[1],"duration":seconds,"elapsed":Date().timeIntervalSince(start)]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("report.json"))
        print("DONE \(index)")
    }
}
