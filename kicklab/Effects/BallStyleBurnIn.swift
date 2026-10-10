import AVFoundation
import Combine
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

@MainActor
final class BallStyleBurnIn: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var outputURL: URL?
    @Published private(set) var status = ""

    private struct Request: Equatable {
        let source: URL
        let style: BallStyle
        let skin: BallSkin
        let intensity: Double
        let environment: EffectEnvironment
        let shortEdge: Int
        let counter: ExportCounterTimeline?
        let overlays: ExportOverlaySettings?
        let preserveFrameTimes: Bool
        let maskSignature: Int
        let distanceTimeline: BallDistanceTimeline?
        let motionTimeline: MotionStyleTimeline?
    }
    private var completedRequest: Request?
    private var worker: Task<Void, Never>?
    func cancel() { worker?.cancel() }

    func export(source: URL, track: [RecordedFrame], style: BallStyle, intensity: Double,
                skin: BallSkin = .original, environment: EffectEnvironment = .original, shortEdge: Int = 1080,
                counter: ExportCounterTimeline? = nil, overlays: ExportOverlaySettings? = nil,preserveFrameTimes:Bool=false,
                distanceTimeline: BallDistanceTimeline? = nil, motionTimeline: MotionStyleTimeline? = nil) {
        guard !isExporting else { return }
        var maskHasher = Hasher()
        for frame in track {
            maskHasher.combine(frame.time); maskHasher.combine(frame.usesBallMasks)
            if let mask = frame.ballMask { maskHasher.combine(mask.alpha) }
        }
        let request = Request(source: source, style: style, skin: skin, intensity: intensity, environment: environment, shortEdge: shortEdge, counter: counter, overlays: overlays,preserveFrameTimes:preserveFrameTimes, maskSignature: maskHasher.finalize(), distanceTimeline: distanceTimeline, motionTimeline: motionTimeline)
        if completedRequest == request, let outputURL, FileManager.default.fileExists(atPath: outputURL.path) { return }
        isExporting = true; progress = 0; outputURL = nil; status = "Preparing video…"
        worker = Task {
            do {
                let url = try await VideoBackgroundWork.shared.run(title: "Exporting video",
                    requiresGPU: (style != .none && intensity > 0) || environment != .original) {
                    let renderTask = VideoWorkExecution.detached {
                        try await Self.render(source: source, track: track, style: style, skin: skin,
                                              intensity: intensity, environment: environment, shortEdge: shortEdge, counter: counter, overlays: overlays,preserveFrameTimes:preserveFrameTimes, distanceTimeline: distanceTimeline, motionTimeline: motionTimeline) { p in
                            VideoWorkExecution.lease?.progress(p, subtitle: p < 0.94 ? "Rendering your video" : "Finishing video")
                            await MainActor.run { self.progress = p; self.status = p < 0.94 ? "Rendering effects…" : "Finishing video…" }
                        }
                    }
                    return try await withTaskCancellationHandler { try await renderTask.value } onCancel: { renderTask.cancel() }
                }
                outputURL = url; completedRequest = request; status = "Ready"; progress = 1
            } catch is CancellationError {
                status = "Export stopped. Tap Download to try again."
            } catch {
                status = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false; worker = nil
        }
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "KickLab.Export", code: 50, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Used by the app and real-video integration harness. Never falls back to an
    /// unedited source when rendering fails. Source audio is muxed back losslessly.
    nonisolated static func render(source: URL, track: [RecordedFrame], style: BallStyle,
                                  skin: BallSkin = .original, intensity: Double, environment: EffectEnvironment = .original, shortEdge: Int = 1080,
                                  counter: ExportCounterTimeline? = nil,
                                  overlays: ExportOverlaySettings? = nil,
                                  touchTimes: [Double]? = nil,
                                  preserveFrameTimes:Bool=false,
                                  distanceTimeline: BallDistanceTimeline? = nil,
                                  motionTimeline: MotionStyleTimeline? = nil,
                                  onProgress: @Sendable (Double) async -> Void = { _ in }) async throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track.") }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let composition = try await EffectVideoGeometry.composition(track: videoTrack, duration: duration, shortEdge: shortEdge)
        let size = composition.renderSize
        var effects = BallEffectTrack(frames: track, touchTimes: touchTimes ?? counter?.times ?? [])
        if skin != .original {
            effects.surfaceMotion = try await BallSurfaceTimeline.prepare(source: source, track: effects)
        }
        let graphTimeline: MotionStyleTimeline? = overlays?.graph.enabled == true
            ? motionTimeline ?? MotionStyleTimeline(points: track.map {
                CaptureMotionPoint(time: $0.time, y: $0.detected ? $0.y : nil, x: $0.detected ? $0.x : nil)
            }, touchTimes: touchTimes ?? counter?.times ?? []) : nil
        let reader = try AVAssetReader(asset: asset)
        let output: AVAssetReaderOutput
        if preserveFrameTimes {
            // Prepared scenes are already upright SDR. Read their actual frames
            // instead of resampling a second time from estimated nominal FPS.
            guard try await videoTrack.load(.preferredTransform).isIdentity else {throw failure("The prepared scene has an unexpected orientation.")}
            output=AVAssetReaderTrackOutput(track:videoTrack,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        } else {
            let composed=AVAssetReaderVideoCompositionOutput(videoTracks:[videoTrack],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            composed.videoComposition=composition;output=composed
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw failure("Cannot decode video.") }
        reader.add(output)
        let temp = FileManager.default.temporaryDirectory
        // AVFoundation drops the QuickTime playback-intent key in MP4 files.
        // High-frame-rate replays need MOV to retain that intent in Photos.
        let highFrameRate = try await videoTrack.load(.nominalFrameRate) > 60
        let fileType: AVFileType = highFrameRate ? .mov : .mp4
        let fileExtension = highFrameRate ? "mov" : "mp4"
        let silentURL = temp.appendingPathComponent("juggledude-render-\(UUID().uuidString).\(fileExtension)")
        let finalURL = temp.appendingPathComponent("juggledude-edited-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: silentURL) }
        let writer = try AVAssetWriter(outputURL: silentURL, fileType: fileType)
        // Photos may otherwise interpret 120/240 fps exports as slow motion.
        // Keep the original timestamps and explicitly request full-speed playback.
        let playbackIntent = AVMutableMetadataItem()
        playbackIntent.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
        playbackIntent.dataType = kCMMetadataBaseDataType_UInt8 as String
        playbackIntent.value = NSNumber(value: 1)
        writer.metadata = [playbackIntent]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: shortEdge >= 1080 ? 14_000_000 : 7_000_000]])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 60_000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw failure("Cannot encode video.") }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? failure("Cannot start export.") }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: silentURL.path)
        writer.startSession(atSourceTime: .zero)
        let edit = SessionEditState(style: style, intensity: intensity, ballSkin: skin, environment: environment)
        let needsGPU = (style != .none && intensity > 0) || environment != .original
        try await VideoWorkExecution.checkpoint(requiresGPU: needsGPU)
        let engine = needsGPU ? try MetalEffectEngine() : nil
        let ci = engine.map { CIContext(mtlDevice: $0.device, options: [.cacheIntermediates: false]) }
            ?? CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly, .cacheIntermediates: false])
        var frameCount = 0
        do {
            while true {
                try await VideoWorkExecution.checkpoint(requiresGPU: needsGPU)
                guard let buffer = output.copyNextSampleBuffer() else { break }
                try Task.checkCancellation()
                guard let pixels = CMSampleBufferGetImageBuffer(buffer), let pool = adaptor.pixelBufferPool else {
                    throw failure("Missing decoded frame or pixel buffer pool.")
                }
                let stamp = CMSampleBufferGetPresentationTimeStamp(buffer)
                let time = CMTimeGetSeconds(stamp)
                while !input.isReadyForMoreMediaData {
                    try await VideoWorkExecution.checkpoint(requiresGPU: needsGPU)
                    guard writer.status == .writing else { throw writer.error ?? failure("Encoder stopped.") }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let graphImage: CGImage?
                if let graphTimeline, let graph = overlays?.graph {
                    graphImage = await ExportMotionGraphRenderer.image(style: graph.style,
                        snapshot: graphTimeline.snapshot(at: time, duration: seconds), size: size)
                    guard graphImage != nil else { throw failure("Cannot render the motion graph.") }
                } else { graphImage = nil }
                try autoreleasepool {
                    var target: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target) == kCVReturnSuccess,
                          let target else { throw failure("Cannot allocate video frame.") }
                    var image=CIImage(cvPixelBuffer:pixels)
                    if preserveFrameTimes,image.extent.size != size {
                        image=image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:size.height/image.extent.height,
                            kCIInputAspectRatioKey:(size.width/image.extent.width)/(size.height/image.extent.height)])
                    }
                    ci.render(image, to: target)
                    #if DEBUG
                    try PipelineParityReview.exportPixels(target, time: time, stage: "source")
                    #endif
                    if skin != .original {
                        let sample = effects.replacementGuide(at: time)
                        let mask = effects.mask(at: time)
                        // Measure on the decoder's pixels, as replay and source spin do.
                        // Core Image's output color conversion can change edge scores
                        // enough to select a different outline on a blurred ball.
                        // Keep geometry in source coordinates; the normalized patch
                        // rect handles prepared scenes whose output size differs.
                        let appearanceSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                        let fitted = sample.flatMap { BallReplacementFootprint.fit(pixels: pixels, sample: $0, measureTexture: true) }
                        let smear = effects.smear(at: time, size: appearanceSize)
                        let matte = mask.map { BallReplacementCoverage(mask: $0, fitted: fitted, size: appearanceSize, smear: smear) }
                        let footprint = effects.usesBallMasks ? matte?.footprint : fitted
                        let coverage: ((Double, Double) -> Double)? = matte.map { m in
                            { x, y in m.coverage(x: x, y: y) }
                        }
                        let replacement = BallMaterialRenderer.replacement(footprint: footprint, skin: skin,
                            time: time, coverage: coverage, coverageBounds: matte?.bounds,
                            orientation: effects.surfaceMotion?.renderOrientation(at: time), smear: smear,
                            light: effects.surfaceMotion?.light(at: time))
                        CVPixelBufferLockBaseAddress(target, [])
                        do {
                            defer { CVPixelBufferUnlockBaseAddress(target, []) }
                            guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(target), width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(target), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                                throw failure("Cannot create the ball material context.")
                            }
                            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
                            // Match replay: weak outline support leaves source pixels intact.
                            BallMaterialRenderer.draw(in: ctx, size: size, sourceSize: appearanceSize, skin: skin, sample: replacement == nil ? nil : sample, time: time, replacement: replacement)
                        }
                        #if DEBUG
                        try PipelineParityReview.exportPixels(target, time: time, stage: "composite", fitted: fitted,
                            material: footprint, orientation: effects.surfaceMotion?.renderOrientation(at: time))
                        #endif
                    }
                    if let engine {
                        let frame = EffectFrame.video(size: size, sourceSize: size, edit: edit, track: effects, time: time)
                        try engine.composite(frame, pixelBuffer: target)
                    }
                    if overlays?.hasVisibleOverlays == true || (overlays == nil && counter != nil) || distanceTimeline != nil {
                        CVPixelBufferLockBaseAddress(target, [])
                        defer { CVPixelBufferUnlockBaseAddress(target, []) }
                        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(target), width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(target), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                            throw failure("Cannot draw the video overlays.")
                        }
                        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                        if var overlays {
                            // A missing event timeline must not invent a count.
                            overlays.counter.enabled = overlays.counter.enabled && counter != nil
                            ExportOverlayRenderer.draw(in: context, size: size, settings: overlays, time: time,
                                counter: counter?.state(at: time) ?? .init(count: 0, isTotal: true, age: nil))
                        } else if let counter {
                            ExportCounterRenderer.draw(in: context, size: size, state: counter.state(at: time))
                        }
                        if let graphImage, let graph = overlays?.graph {
                            ExportMotionGraphRenderer.draw(graphImage, in: context, style: graph.style, size: size)
                        }
                        if let distanceTimeline {
                            BallDistanceBadgeRenderer.draw(in: context, size: size, state: distanceTimeline.state(at: time))
                        }
                    }
                    #if DEBUG
                    try PipelineParityReview.exportHash(target,time:time,stage:"encoder")
                    #endif
                    guard adaptor.append(target, withPresentationTime: stamp) else { throw writer.error ?? failure("Cannot append rendered frame.") }
                }
                frameCount += 1
                if frameCount % 12 == 0 { await onProgress(min(0.94, time / max(seconds, 0.1) * 0.94)) }
            }
            guard reader.status == .completed, frameCount > 0 else { throw reader.error ?? failure("Video decoding did not finish.") }
            input.markAsFinished()
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? failure("Video encoding did not finish.") }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
        try await VideoWorkExecution.checkpoint()
        await onProgress(0.95)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if audioTracks.isEmpty {
            try FileManager.default.moveItem(at: silentURL, to: finalURL)
        } else {
            let mux = AVMutableComposition()
            let rendered = AVURLAsset(url: silentURL)
            guard let renderedTrack = try await rendered.loadTracks(withMediaType: .video).first,
                  let destination = mux.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw failure("Cannot finish video.")
            }
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: renderedTrack, at: .zero)
            for audio in audioTracks {
                let range = try await audio.load(.timeRange)
                let available = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, duration: duration))
                guard available.duration > .zero,
                      let dest = mux.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try dest.insertTimeRange(available, of: audio, at: available.start)
            }
            guard let session = AVAssetExportSession(asset: mux, presetName: AVAssetExportPresetPassthrough) else { throw failure("Cannot preserve audio.") }
            // A new composition does not inherit the writer's movie-level metadata.
            session.metadata = [playbackIntent]
            do { try await session.export(to: finalURL, as: fileType) }
            catch { try? FileManager.default.removeItem(at: finalURL); throw error }
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: finalURL.path)
        await onProgress(1)
        return finalURL
    }
}
