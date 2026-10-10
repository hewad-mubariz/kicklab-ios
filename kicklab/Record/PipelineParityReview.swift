#if DEBUG
import AVFoundation
import CoreImage
import CoreML
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import simd

/// Opt-in local engineering evidence. Never runs in normal capture or export.
nonisolated enum PipelineParityReview {
    static let times: [Double] = [0, 0.666667, 1.666667, 1.683333, 1.816667, 3.033333,
        5.383333, 5.85, 6.233333, 10.383333, 12.383333, 14.616667, 14.916667,
        15.183333, 15.216667, 15.25]
    static func selected(_ time: Double) -> Bool { times.contains { abs($0-time)<0.002 } }
    static func label(_ time: Double) -> String { String(format:"%06d",Int((time*60000).rounded())) }
    static let enabled = ProcessInfo.processInfo.arguments.contains("--pipeline-parity")
    static var folder: URL { URL.documentsDirectory.appendingPathComponent("pipeline-parity",isDirectory:true) }

    static func begin() throws {
        guard enabled else { return }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func exportPixels(_ pixels: CVPixelBuffer, time: Double, stage: String,
                             fitted: BallReplacementFootprint? = nil,
                             material: BallReplacementFootprint? = nil,
                             orientation: simd_quatf? = nil) throws {
        try exportHash(pixels,time:time,stage:stage)
        guard enabled, selected(time) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let ptr = CVPixelBufferGetBaseAddress(pixels)!, stride = CVPixelBufferGetBytesPerRow(pixels)
        var packed = Data(capacity: width * height * 4)
        for y in 0..<height { packed.append(ptr.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self), count:width*4) }
        let prefix = folder.appendingPathComponent(label(time) + ".export-" + stage)
        try packed.write(to: prefix.appendingPathExtension("bgra"))
        if stage == "composite" {
            var meta: [String: Any] = ["time": time]
            if let fitted { meta["fitted"] = describe(fitted) }
            if let material { meta["material"] = describe(material) }
            if let orientation { meta["q"] = [orientation.vector.x, orientation.vector.y, orientation.vector.z, orientation.vector.w] }
            try JSONSerialization.data(withJSONObject: meta, options: .sortedKeys).write(to: prefix.appendingPathExtension("json"))
        }
    }

    /// Exact raster evidence, including the frame supplied to the encoder.
    /// Diagnostic only; no hashes or additional pixel reads on normal exports.
    static func exportHash(_ pixels: CVPixelBuffer, time: Double, stage: String) throws {
        guard ProcessInfo.processInfo.arguments.contains("--export-frame-hashes"),
              let name=SessionDesignReview.argument("--effects-folder") else { return }
        let directory=URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath:name).lastPathComponent)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        CVPixelBufferLockBaseAddress(pixels,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
        let width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels)
        let base=CVPixelBufferGetBaseAddress(pixels)!,stride=CVPixelBufferGetBytesPerRow(pixels)
        var digest=SHA256()
        for y in 0..<height {
            digest.update(data:Data(bytesNoCopy:base.advanced(by:y*stride),count:width*4,deallocator:.none))
        }
        let row:[String:Any]=["time":time,"width":width,"height":height,
            "sha256":digest.finalize().map {String(format:"%02x",$0)}.joined()]
        let file=directory.appendingPathComponent("export-\(stage)-hashes.jsonl")
        if !FileManager.default.fileExists(atPath:file.path) {FileManager.default.createFile(atPath:file.path,contents:nil)}
        let handle=try FileHandle(forWritingTo:file);defer {try? handle.close()}
        try handle.seekToEnd();try handle.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:.sortedKeys)+Data([10]))
    }

    static func model(input: MLFeatureProvider, output: MLFeatureProvider, time: Double, content: CGRect,
                      sourceSize: CGSize, threshold: Double) throws {
        guard enabled, selected(time) else {return}
        let directory=folder.appendingPathComponent("model-"+label(time),isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var shapes=[String:[Int]]()
        for (provider,names) in [(input,["image"]),(output,["boxes","scores","labels","mask_coefficients","mask_prototypes"])] {
            for name in names {
                guard let array=provider.featureValue(for:name)?.multiArrayValue else {continue}
                let values=(0..<array.count).map {array[$0].floatValue}
                try values.withUnsafeBytes {try Data($0).write(to:directory.appendingPathComponent(name+".f32"))}
                shapes[name]=array.shape.map(\.intValue)
            }
        }
        var metadata:[String:Any]=["time":time,"shapes":shapes,"content":[content.minX,content.minY,content.width,content.height],
            "source_size":[sourceSize.width,sourceSize.height],"threshold":threshold]
        if let mask=BallMask.decode(output,content:content,sourceSize:sourceSize,threshold:threshold) {
            metadata["primary_mask"]=["rect":[mask.rect.minX,mask.rect.minY,mask.rect.width,mask.rect.height],
                "width":mask.width,"height":mask.height,"alpha":Data(mask.alpha).base64EncodedString()]
        }
        try JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys)
            .write(to:directory.appendingPathComponent("metadata.json"))
    }

    static func write(source: URL, frames: [RecordedFrame]) async throws {
        guard enabled else {return}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("RUNNING".utf8).write(to:folder.appendingPathComponent("status.txt"))
        var track=BallEffectTrack(frames:frames)
        track.surfaceMotion=try await BallSurfaceTimeline.prepare(source:source,track:track)
        let asset=AVURLAsset(url:source),video=try await asset.loadTracks(withMediaType:.video)[0]
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[video],
            videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.videoComposition=try await EffectVideoGeometry.composition(track:video,duration:asset.load(.duration),shortEdge:720)
        output.alwaysCopiesSampleData=false;reader.add(output)
        guard reader.startReading() else {throw reader.error!}
        defer {if reader.status == .reading {reader.cancelReading()}}
        let patchURL=folder.appendingPathComponent("spin-patches.f32")
        FileManager.default.createFile(atPath:patchURL.path,contents:nil)
        let handle=try FileHandle(forWritingTo:patchURL);defer {try? handle.close()}
        let ci=CIContext(options:[.workingColorSpace:NSNull()])
        var rows=[[String:Any]](),index=0,patchIndex=0
        var previous:BallSurfaceMotion.Gray?,previousTime:Double?
        while let buffer=output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let pixels=CMSampleBufferGetImageBuffer(buffer) else {return}
                let pts=CMSampleBufferGetPresentationTimeStamp(buffer),time=CMTimeGetSeconds(pts)
                let size=CGSize(width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels))
                let sample=track.replacementGuide(at:time),mask=track.mask(at:time)
                let fitted=sample.flatMap {BallReplacementFootprint.fit(pixels:pixels,sample:$0,measureTexture:true)}
                let smear=track.smear(at:time,size:size)
                let matte=mask.map {BallReplacementCoverage(mask:$0,fitted:fitted,size:size,smear:smear)}
                let pose=track.surfaceMotion!.orientation(at:time)
                var row:[String:Any]=["index":index,"time":time,"pts_value":pts.value,"pts_scale":pts.timescale,
                    "size":[size.width,size.height],"q":[pose.vector.x,pose.vector.y,pose.vector.z,pose.vector.w],
                    "spin_status":track.surfaceMotion!.status(at:time).rawValue,"patch_index":-1,"selected":selected(time)]
                if let sample {row["guide"]=[sample.center.x,sample.center.y,sample.boxSize?.width ?? 0,sample.boxSize?.height ?? 0,sample.confidence]}
                if let mask {row["mask"]=["rect":[mask.rect.minX,mask.rect.minY,mask.rect.width,mask.rect.height],
                    "width":mask.width,"height":mask.height,"alpha":Data(mask.alpha).base64EncodedString()]}
                if let fitted {row["fitted"]=describe(fitted)}
                if let matte {row["material"]=describe(matte.footprint)}
                if let fitted,let sample,sample.confidence>=0.3,
                   let patch=BallSurfaceMotion.patch(pixels:pixels,center:fitted.center,radius:fitted.radii.reduce(0,+)/Double(fitted.radii.count)) {
                    try patch.values.withUnsafeBytes {try handle.write(contentsOf:Data($0))}
                    row["patch_index"]=patchIndex;patchIndex += 1
                    if let previous,let previousTime,time>previousTime,time-previousTime<0.06 {
                        let fit=BallSurfaceMotion.estimate(previous:previous,current:patch)
                        row["spin_fit"]=["accepted":fit.accepted,"rotation":[fit.rotation.x,fit.rotation.y,fit.rotation.z],
                            "matches":fit.matches,"residual":fit.residual.isFinite ? fit.residual:-1,
                            "disagreement":fit.disagreement.isFinite ? fit.disagreement:-1]
                    }
                    previous=patch;previousTime=time
                } else {previous=nil;previousTime=nil}
                if selected(time) {
                    let prefix=folder.appendingPathComponent(label(time))
                    let sourceImage=ci.createCGImage(CIImage(cvPixelBuffer:pixels),from:CGRect(origin:.zero,size:size))!
                    try png(sourceImage,prefix.appendingPathExtension("source.png"))
                    let sphere=BallSkinSphereRenderer.image(skin:.galaxy,time:time,orientation:pose)!
                    try png(sphere,prefix.appendingPathExtension("sphere.png"))
                    let replacement=BallMaterialRenderer.replacement(footprint:matte?.footprint,skin:.galaxy,time:time,
                        coverage:matte.map {m in {x,y in m.coverage(x:x,y:y)}},coverageBounds:matte?.bounds,orientation:pose,smear:smear,light:track.surfaceMotion?.light(at:time))
                    if let replacement {
                        try png(replacement.image,prefix.appendingPathExtension("patch.png"))
                        row["patch_rect"]=[replacement.rect.minX,replacement.rect.minY,replacement.rect.width,replacement.rect.height]
                    }
                    // Save the same numeric input bytes before any CG composition.
                    CVPixelBufferLockBaseAddress(pixels,[])
                    defer {CVPixelBufferUnlockBaseAddress(pixels,[])}
                    let ptr=CVPixelBufferGetBaseAddress(pixels)!,stride=CVPixelBufferGetBytesPerRow(pixels)
                    var packed=Data()
                    for y in 0..<Int(size.height) {packed.append(ptr.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self),count:Int(size.width)*4)}
                    try packed.write(to:prefix.appendingPathExtension("source.bgra"))
                    let ctx=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:Int(size.width)*4,
                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
                    for y in 0..<Int(size.height) {
                        memcpy(ctx.data!.advanced(by:y*ctx.bytesPerRow),ptr.advanced(by:y*stride),Int(size.width)*4)
                    }
                    ctx.translateBy(x:0,y:size.height);ctx.scaleBy(x:1,y:-1)
                    BallMaterialRenderer.draw(in:ctx,size:size,sourceSize:size,skin:.galaxy,
                        sample:replacement == nil ? nil:sample,time:time,replacement:replacement)
                    try png(ctx.makeImage()!,prefix.appendingPathExtension("composite.png"))
                }
                rows.append(row);index += 1
            }
        }
        guard reader.status == .completed else {throw reader.error!}
        let metadata:[String:Any]=["rows":rows,"patches":patchIndex,"source":source.lastPathComponent,
            "source_digest":try SessionAnalysisStore.sourceDigest(source),
            "pipeline_signature":SessionAnalysisStore.pipelineSignature(),"scope":"DEBUG diagnostic; extra decode/fit only when --pipeline-parity"]
        try JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys).write(to:folder.appendingPathComponent("frames.json"))
        try await playerFrames(source: source, frames: frames)
        try Data("COMPLETE".utf8).write(to:folder.appendingPathComponent("status.txt"))
    }

    @MainActor
    private static func playerFrames(source: URL, frames: [RecordedFrame]) async throws {
        let asset = AVURLAsset(url: source)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = try await EffectVideoGeometry.composition(track: video, duration: asset.load(.duration), shortEdge: 720)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
        output.suppressesPlayerRendering = true
        item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); item.remove(output); player.replaceCurrentItem(with: nil) }
        let track = BallEffectTrack(frames: frames)
        var rows = [[String: Any]]()
        for time in times {
            let requested = CMTime(value: Int64((time * 60000).rounded()), timescale: 60000)
            let sought = await player.seek(to: requested, toleranceBefore: .zero, toleranceAfter: .zero)
            var pixels: CVPixelBuffer?, stamp = CMTime.invalid
            for _ in 0..<100 {
                pixels = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &stamp)
                // A seek completion can precede delivery of its new video buffer.
                // Never label the previously displayed pixels as the requested frame.
                if pixels != nil, stamp.isValid,
                   abs(CMTimeGetSeconds(stamp) - CMTimeGetSeconds(requested)) < 0.001 { break }
                pixels = nil
                try await Task.sleep(for: .milliseconds(20))
            }
            var row: [String: Any] = ["requested": CMTimeGetSeconds(requested), "seek_completed": sought]
            if let pixels {
                let actual = stamp.isValid ? CMTimeGetSeconds(stamp) : CMTimeGetSeconds(requested)
                row["actual"] = actual
                if let sample = track.replacementGuide(at: actual),
                   let fitted = BallReplacementFootprint.fit(pixels: pixels, sample: sample, measureTexture: true) {
                    row["fitted"] = describe(fitted)
                }
                try exportPixels(pixels, time: time, stage: "player")
            } else { row["missing"] = true }
            rows.append(row)
        }
        try JSONSerialization.data(withJSONObject: rows, options: .sortedKeys).write(to: folder.appendingPathComponent("player-frames.json"))
    }

    private static func describe(_ f: BallReplacementFootprint) -> [String:Any] {
        ["center":[f.center.x,f.center.y],"radius":f.radius,"radii":f.radii,"feather":f.feather,
         "padding":f.padding,"textureBlur":f.textureBlur]
    }
    private static func png(_ image: CGImage,_ url: URL) throws {
        guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw NSError(domain:"PipelineParity",code:1)
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else {throw NSError(domain:"PipelineParity",code:2)}
    }
}
#endif
