import AVFoundation
import CoreImage
import CoreGraphics
import Foundation
import Metal
import Vision

nonisolated struct StadiumBallObservation: Sendable {
    let time: Double
    let bounds: CGRect
    let confidence: Double
}

nonisolated struct PreparedStadiumPreview: Sendable {
    let folder: URL
    let original: URL
    // Older prepared samples contain baked stadium movies. New preparations
    // render the selected environment interactively from the shared cutout.
    let locked: URL?
    let moving: URL?
    let duration: Double
    let sourceDuration: Double
    let frames: Int
    let size: CGSize
    var foreground: URL? = nil
    var recording: StadiumSceneRecording? = nil

    func removeFiles() { try? FileManager.default.removeItem(at: folder) }
}

/// A full-length foreground cache shared by scene preview and export.
/// Encoded color, lossless numeric alpha and camera share presentation times.
nonisolated enum StadiumPreviewPreparer {

    /// Saved with the prepared clip so device-only tracking failures can be
    /// traced to the exact decoded frame without guessing from playback.
    private struct CutoutFrame: Codable {
        let time: Double
        let hasPerson: Bool
        let hasBall: Bool
        let ballBounds: CGRect?
        let ballMethod: String
        let ballQuality: Double
        let repairedPersonRegions: Int
    }

    static func prepare(source: URL, observations: [StadiumBallObservation], library: String? = nil, temporalRefinement: Bool = true,
                        personRefinerURL: URL? = nil,
                        maximumFrameRate: Double = 60,
                        diagnostics: (@Sendable (String, Double, CVPixelBuffer, CGRect) throws -> Void)? = nil,
                        onStage: @Sendable (String) async -> Void = { _ in },
                        onProgress: @Sendable (Double) async -> Void = { _ in }) async throws -> PreparedStadiumPreview {
        try Task.checkCancellation()
        await onStage("Opening video")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw failure("This file has no video to preview.")
        }
        let fullDuration = try await asset.load(.duration)
        guard fullDuration.seconds.isFinite, fullDuration.seconds > 0 else { throw failure("This video has no playable duration.") }
        let seconds = fullDuration.seconds
        let duration = CMTime(seconds:seconds,preferredTimescale:60_000)
        let previewComposition = try await EffectVideoGeometry.composition(track:video,duration:fullDuration,shortEdge:1080)
        // Segment before making the editing proxy: a 4K source contains toe,
        // hair and ball-edge detail that cannot be recovered from a 720p proxy.
        let sourceFPS = try await video.load(.nominalFrameRate)
        guard maximumFrameRate.isFinite,maximumFrameRate>0 else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        let preparedFPS=min(60,maximumFrameRate,Double(sourceFPS > 0 ? sourceFPS:30))
        let composition = try await EffectVideoGeometry.composition(track:video,duration:fullDuration,shortEdge:2160,
            frameDuration:CMTime(seconds:1/preparedFPS,preferredTimescale:60_000))
        let size = previewComposition.renderSize
        await onProgress(0.01)
        await onStage("Starting cutout processing")
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw failure("Preparing a cutout needs Metal on this device.")
        }
        try Task.checkCancellation()
        let context = CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
        await onProgress(0.03)
        await onStage("Finding the player throughout your video")
        let calibration = try await StadiumSceneCalibration.make(asset:asset,duration:seconds,size:size,maximumFrameRate:preparedFPS) { value in
            await onProgress(0.03+value*0.12)
        }
        try Task.checkCancellation()
        // Keep native detail around the action instead of magnifying a small
        // player from a full-frame 1080p proxy. Include the ball's whole track.
        var actionRect=calibration.crop
        for ball in observations where ball.confidence>=0.05 && ball.bounds.width>0 && ball.bounds.height>0
            && ball.bounds.minX.isFinite && ball.bounds.minY.isFinite && ball.bounds.width.isFinite && ball.bounds.height.isFinite {
            let rect=ball.bounds.insetBy(dx:-ball.bounds.width*0.8,dy:-ball.bounds.height*0.8)
                .intersection(CGRect(x:0,y:0,width:1,height:1))
            if !rect.isNull {actionRect=actionRect.union(rect)}
        }
        let nativeSize=composition.renderSize
        let cachePixels=CGRect(x:actionRect.minX*nativeSize.width,y:actionRect.minY*nativeSize.height,
            width:actionRect.width*nativeSize.width,height:actionRect.height*nativeSize.height).integral
            .intersection(CGRect(origin:.zero,size:nativeSize))
        let sourceRect=CGRect(x:cachePixels.minX/nativeSize.width,y:cachePixels.minY/nativeSize.height,
            width:cachePixels.width/nativeSize.width,height:cachePixels.height/nativeSize.height)
        let cacheScale=min(1,1080/cachePixels.width,1920/cachePixels.height)
        let cacheSize=CGSize(width:max(2,Int(cachePixels.width*cacheScale)/2*2),height:max(2,Int(cachePixels.height*cacheScale)/2*2))
        let colorCache=try ForegroundMaskProcessor.buffer(width:Int(cacheSize.width),height:Int(cacheSize.height),format:kCVPixelFormatType_32BGRA)
        let maskCache=try ForegroundMaskProcessor.buffer(width:Int(cacheSize.width),height:Int(cacheSize.height),format:kCVPixelFormatType_32BGRA)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kicklab-stadium-preview-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at:folder) } }
        let alphaCache=try LosslessAlphaCache.Writer(folder:folder,width:Int(cacheSize.width),height:Int(cacheSize.height))
        let names = ["original","foreground"]
        var movies: [PreviewMovie] = []
        defer { if !succeeded { for movie in movies { movie.cancel() } } }
        for name in names {
            let movieSize=name == "foreground" ? CGSize(width:cacheSize.width*2,height:cacheSize.height):size
            movies.append(try PreviewMovie(url:folder.appendingPathComponent(name+"-silent.mp4"),size:movieSize,frameRate:preparedFPS))
        }
        let refinerURL=personRefinerURL ?? Bundle.main.url(forResource:PersonMatteRefiner.modelName,withExtension:"mlmodelc")
        await onProgress(0.15)
        await onStage("Loading player cutout model")
        let refiner=try refinerURL.map {try PersonMatteRefiner(modelURL:$0,context:context)}
        try Task.checkCancellation()
        let processor = DetailedForegroundMaskProcessor(sourceCrop:calibration.crop,context:context,refiner:refiner)
        let edges = try ForegroundEdgeProcessor(device:device,context:context,library:library)
        let spatialProbe = try diagnostics.map { _ in try ForegroundEdgeProcessor(device:device,context:context,library:library) }
        let cameraMotion=StadiumCameraMotion(personCrop:calibration.crop,context:context,camera:calibration.camera)
        var cameraFrames: [StadiumSceneRecording.Frame] = []
        var cutoutFrames: [CutoutFrame] = []
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String:true])
        output.videoComposition = composition; output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw failure("This video could not be decoded.") }
        reader.add(output); reader.timeRange = CMTimeRange(start:.zero,duration:duration)
        guard reader.startReading() else { throw reader.error ?? failure("The preview could not start.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var contacts = FootContactTracker(), frameCount = 0, observationIndex = 0
        let balls = observations.filter { $0.time.isFinite && $0.confidence >= 0.05 && $0.bounds.width > 0 && $0.bounds.height > 0 }.sorted { $0.time < $1.time }
        await onStage("Separating the player and ball")
        while true {
            try await VideoWorkExecution.checkpoint(requiresGPU: true)
            guard let sample = output.copyNextSampleBuffer() else { break }
            try Task.checkCancellation()
            guard let sourcePixels = CMSampleBufferGetImageBuffer(sample) else { throw failure("A video frame could not be read.") }
            let stamp = CMSampleBufferGetPresentationTimeStamp(sample), time = stamp.seconds
            while observationIndex+1 < balls.count, balls[observationIndex+1].time <= time { observationIndex += 1 }
            let nearest = [observationIndex,observationIndex+1].filter { $0 < balls.count }
                .map { balls[$0] }.min { abs($0.time-time) < abs($1.time-time) }
            let ball = nearest.flatMap { abs($0.time-time) <= 0.025 ? $0.bounds : nil }
            let products: [CVPixelBuffer] = try autoreleasepool {
                let matte = try processor.process(sourcePixels,at:time,ball:ball,ballConfidence:ball == nil ? 0:nearest?.confidence ?? 0,
                    trace: diagnostics.map { observer in { name,pixels,rect in try observer(name,time,pixels,rect) } })
                cutoutFrames.append(CutoutFrame(time:time,hasPerson:DetailedForegroundMaskProcessor.containsPerson(matte.person),
                    hasBall:matte.ball != nil,ballBounds:processor.lastBallBounds,
                    ballMethod:processor.lastBallMethod,ballQuality:processor.lastBallQuality,repairedPersonRegions:processor.lastPersonRepairCount))
                var camera = calibration.camera
                camera.movement=0
                camera.recordedPan=try cameraMotion.update(sourcePixels)
                camera.contact = contacts.update(VisibleFootContact.measure(person:matte.person,rect:matte.personRect),at:time)
                cameraFrames.append(.init(time:time,contact:camera.contact,pan:camera.recordedPan))
                let original = try movies[0].buffer()
                let sourceImage = CIImage(cvPixelBuffer:sourcePixels)
                let resized = sourceImage.applyingFilter("CILanczosScaleTransform",parameters:[
                    kCIInputScaleKey:size.width/sourceImage.extent.width,kCIInputAspectRatioKey:1])
                context.render(resized,to:original)
                let roi=CGRect(x:cachePixels.minX,y:nativeSize.height-cachePixels.maxY,width:cachePixels.width,height:cachePixels.height)
                func cachedCrop(_ image:CIImage)->CIImage {
                    image.cropped(to:roi).transformed(by:CGAffineTransform(translationX:-roi.minX,y:-roi.minY))
                        .transformed(by:CGAffineTransform(scaleX:cacheSize.width/roi.width,y:cacheSize.height/roi.height))
                }
                context.render(cachedCrop(sourceImage),to:colorCache)
                context.render(cachedCrop(matte.image(size:nativeSize)),to:maskCache,
                    bounds:CGRect(origin:.zero,size:cacheSize),colorSpace:nil)
                try diagnostics?("cache-source",time,colorCache,sourceRect)
                try diagnostics?("combined",time,maskCache,sourceRect)
                if let spatialProbe {
                    let spatial=try spatialProbe.process(color:colorCache,mask:maskCache,at:time,temporal:false)
                    try diagnostics?("spatial-alpha",time,spatial.alpha,sourceRect)
                }
                let foreground=try movies[1].buffer()
                let refined=try edges.process(color:colorCache,mask:maskCache,at:time,temporal:temporalRefinement)
                try diagnostics?("refined-alpha",time,refined.alpha,sourceRect)
                try diagnostics?("refined-color",time,refined.color,sourceRect)
                try alphaCache.append(refined.alpha,at:time)
                try Self.pack(color:refined.color,mask:refined.alpha,into:foreground)
                // The lossless alpha index uses this color presentation time;
                // playback resolves both before committing a displayed frame.
                return [original,foreground]
            }
            for index in movies.indices { try await movies[index].append(products[index],time:stamp) }
            frameCount += 1
            await onProgress(0.15+min(1,(time+1/preparedFPS)/seconds)*0.75)
        }
        guard reader.status == .completed, frameCount > 0 else { throw reader.error ?? failure("The video stopped before the preview was complete.") }
        await onStage("Finishing preview video")
        for movie in movies { try await movie.finish(duration:duration) }
        try alphaCache.finish()
        let audio = try await asset.loadTracks(withMediaType:.audio)
        await onStage("Keeping original audio")
        for (index,name) in names.enumerated() {
            try Task.checkCancellation()
            try await preserveAudio(silent:folder.appendingPathComponent(name+"-silent.mp4"),
                destination:folder.appendingPathComponent(name+".mp4"),audio:audio,duration:duration)
            await onProgress(0.90+Double(index+1)/Double(names.count)*0.10)
        }
        try Task.checkCancellation()
        let recording=StadiumSceneRecording(camera:calibration.camera,frames:cameraFrames,sourceRect:sourceRect,matteVersion:2,temporalRefinement:temporalRefinement,
            personRefinement:refiner == nil ? nil:PersonMatteRefiner.version,losslessAlpha:true)
        try JSONEncoder().encode(recording).write(to:folder.appendingPathComponent("scene.json"),options:.atomic)
        try JSONEncoder().encode(cutoutFrames).write(to:folder.appendingPathComponent("cutout-frames.json"),options:.atomic)
        succeeded = true
        return PreparedStadiumPreview(folder:folder,original:folder.appendingPathComponent("original.mp4"),
            locked:nil,moving:nil,
            duration:seconds,sourceDuration:fullDuration.seconds,frames:frameCount,size:size,
            foreground:folder.appendingPathComponent("foreground.mp4"),recording:recording)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain:"KickLab.StadiumPreview",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }

    static func pack(color:CVPixelBuffer,mask:CVPixelBuffer,into target:CVPixelBuffer) throws {
        let w=CVPixelBufferGetWidth(color),h=CVPixelBufferGetHeight(color)
        guard CVPixelBufferGetWidth(mask)==w,CVPixelBufferGetHeight(mask)==h,
              CVPixelBufferGetWidth(target)==w*2,CVPixelBufferGetHeight(target)==h,
              [color,mask,target].allSatisfy({CVPixelBufferGetPixelFormatType($0)==kCVPixelFormatType_32BGRA})
        else {throw ForegroundMaskProcessor.Failure.invalidFrame}
        CVPixelBufferLockBaseAddress(color,.readOnly);CVPixelBufferLockBaseAddress(mask,.readOnly);CVPixelBufferLockBaseAddress(target,[])
        defer {CVPixelBufferUnlockBaseAddress(target,[]);CVPixelBufferUnlockBaseAddress(mask,.readOnly);CVPixelBufferUnlockBaseAddress(color,.readOnly)}
        let c=CVPixelBufferGetBaseAddress(color)!,m=CVPixelBufferGetBaseAddress(mask)!,out=CVPixelBufferGetBaseAddress(target)!
        for y in 0..<h {
            let row=out+y*CVPixelBufferGetBytesPerRow(target)
            memcpy(row,c+y*CVPixelBufferGetBytesPerRow(color),w*4)
            memcpy(row+w*4,m+y*CVPixelBufferGetBytesPerRow(mask),w*4)
        }
    }

    static func preserveAudio(silent: URL, destination: URL, audio: [AVAssetTrack], duration: CMTime) async throws {
        guard !audio.isEmpty else { try FileManager.default.moveItem(at:silent,to:destination); return }
        let asset = AVURLAsset(url:silent), composition = AVMutableComposition()
        guard let source = try await asset.loadTracks(withMediaType:.video).first,
              let target = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else {
            throw failure("The preview could not be finished.")
        }
        // Encoders quantize duration to the movie timescale (often 1/600 s).
        // Intersect with the encoded track to avoid extending video past its
        // available samples. Audio retains its own original sample range.
        let videoRange = CMTimeRangeGetIntersection(try await source.load(.timeRange),
            otherRange: CMTimeRange(start: .zero, duration: duration))
        guard videoRange.duration > .zero else { throw failure("The scene contains no encoded video.") }
        do { try target.insertTimeRange(videoRange,of:source,at:videoRange.start) }
        catch { throw failure("Couldn’t assemble scene frames: \(error)") }
        for track in audio {
            let range = CMTimeRangeGetIntersection(try await track.load(.timeRange),otherRange:CMTimeRange(start:.zero,duration:duration))
            guard range.duration > .zero, let target = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { continue }
            do { try target.insertTimeRange(range,of:track,at:range.start) }
            catch { throw failure("Couldn’t assemble original audio: \(error)") }
        }
        guard let export = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else { throw failure("The original audio could not be added.") }
        do { try await export.export(to:destination,as:.mp4) }
        catch { throw failure("Couldn’t finish the scene with audio: \(error)") }
        try FileManager.default.removeItem(at:silent)
    }
}

nonisolated final class PreviewMovie {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    init(url: URL, size: CGSize, frameRate: Double = 30) throws {
        writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
        input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height),
            AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:(size.width>1500 ? 24_000_000.0:12_000_000.0)*max(1,min(2,frameRate/30)),
                AVVideoExpectedSourceFrameRateKey:max(1,Int(frameRate.rounded()))]])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 60_000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String:Int(size.width),kCVPixelBufferHeightKey as String:Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true])
        guard writer.canAdd(input) else { throw StadiumPreviewPreparer.failure("This preview could not be encoded.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StadiumPreviewPreparer.failure("The preview could not start encoding.") }
        writer.startSession(atSourceTime:.zero)
    }
    func buffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&result) == kCVReturnSuccess, let result else {
            throw ForegroundMaskProcessor.Failure.allocation
        }
        return result
    }
    func append(_ buffer: CVPixelBuffer, time: CMTime) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? StadiumPreviewPreparer.failure("Preview encoding stopped.") }
            try await Task.sleep(for:.milliseconds(2))
        }
        guard adaptor.append(buffer,withPresentationTime:time) else { throw writer.error ?? StadiumPreviewPreparer.failure("A preview frame could not be saved.") }
    }
    func finish(duration: CMTime) async throws {
        try Task.checkCancellation()
        input.markAsFinished(); writer.endSession(atSourceTime:duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StadiumPreviewPreparer.failure("Preview encoding did not finish.") }
    }
    func cancel() { if writer.status == .writing { writer.cancelWriting() } }
}
