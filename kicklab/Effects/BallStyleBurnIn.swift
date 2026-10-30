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

    private var worker: Task<Void, Never>?
    func cancel() { worker?.cancel() }
    func cancelAndWait() async {
        let task = worker
        task?.cancel()
        await task?.value
    }

    func export(source: URL, track: [RecordedFrame], style: BallStyle, intensity: Double,
                skin: BallSkin = .original, environment: EffectEnvironment = .original, shortEdge: Int = 1080,
                counter: ExportCounterTimeline? = nil, overlays: ExportOverlaySettings? = nil,preserveFrameTimes:Bool=false,
                distanceTimeline: BallDistanceTimeline? = nil, motionTimeline: MotionStyleTimeline? = nil,
                ballChanges: [Int: BallSkin] = [:], swapEffect: BallSwapEffect = .none, soundtrack: ReplaySoundtrack? = nil,
                clipAudio: Bool = true) {
        guard !isExporting else { return }
        // Each explicit export renders its current inputs. Reusing by a partial
        // track hash could return an older video after geometry/source changes.
        isExporting = true; progress = 0; outputURL = nil; status = "Preparing video…"
        worker = Task {
            do {
                let url = try await VideoBackgroundWork.shared.run(title: "Exporting video",
                    requiresGPU: (style != .none && intensity > 0) || environment != .original) {
                    let renderTask = VideoWorkExecution.detached {
                        try await Self.render(source: source, track: track, style: style, skin: skin,
                                              intensity: intensity, environment: environment, shortEdge: shortEdge, counter: counter, overlays: overlays,preserveFrameTimes:preserveFrameTimes, distanceTimeline: distanceTimeline, motionTimeline: motionTimeline,
                                              ballChanges: ballChanges, swapEffect: swapEffect, soundtrack: soundtrack,
                                              clipAudio: clipAudio) { p in
                            VideoWorkExecution.lease?.progress(p, subtitle: p < 0.94 ? "Rendering your video" : "Finishing video")
                            await MainActor.run { self.progress = p; self.status = p < 0.94 ? "Rendering effects…" : "Finishing video…" }
                        }
                    }
                    return try await withTaskCancellationHandler { try await renderTask.value } onCancel: { renderTask.cancel() }
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    throw CancellationError()
                }
                outputURL = url; status = "Ready"; progress = 1
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

    nonisolated static func bitrate(for outputSize: CGSize) -> Int {
        min(outputSize.width, outputSize.height) >= 1080 ? 14_000_000 : 7_000_000
    }

    /// Bypass composition only when it would apply neither a transform nor a
    /// color conversion. Unknown/HDR formats, effects and resized video retain
    /// the established composition path.
    nonisolated static func canReadDirectly(naturalSize: CGSize, outputSize: CGSize,
                                          transform: CGAffineTransform, formats: [CMFormatDescription]) -> Bool {
        guard naturalSize == outputSize, transform.isIdentity, !formats.isEmpty else { return false }
        return formats.allSatisfy { format in
            let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(format,
                usePixelAspectRatio: true, useCleanAperture: true)
            return dimensions == naturalSize
                && CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String == AVVideoColorPrimaries_ITU_R_709_2
                && CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == AVVideoTransferFunction_ITU_R_709_2
                && CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String == AVVideoYCbCrMatrix_ITU_R_709_2
        }
    }

    /// The composition already produced upright SDR BGRA pixels. A basic
    /// counter/timer export can copy these into its writable buffer directly,
    /// avoiding a GPU render followed immediately by a CPU overlay readback.
    nonisolated static func copyBGRA(_ source: CVPixelBuffer, to target: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(target) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(target) == width, CVPixelBufferGetHeight(target) == height,
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(target) else { return false }
        let srcStride = CVPixelBufferGetBytesPerRow(source), dstStride = CVPixelBufferGetBytesPerRow(target)
        for row in 0..<height {
            memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), width * 4)
        }
        return true
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
                                  ballChanges: [Int: BallSkin] = [:],
                                  swapEffect: BallSwapEffect = .none,
                                  soundtrack: ReplaySoundtrack? = nil,
                                  clipAudio: Bool = true,
                                  onProgress: @Sendable (Double) async -> Void = { _ in }) async throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track.") }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        try VideoSafetyPolicy.requireExportSpace(duration: seconds)
        let composition = try await EffectVideoGeometry.composition(track: videoTrack, duration: duration, shortEdge: shortEdge)
        let size = composition.renderSize
        var effects = BallEffectTrack(frames: track, touchTimes: touchTimes ?? counter?.times ?? [])
        // Any print, on the whole clip or from one touch on, needs the source spin.
        let usesMaterial = skin != .original || ballChanges.values.contains { $0 != .original }
        if usesMaterial {
            effects.surfaceMotion = try await BallSurfaceTimeline.prepare(source: source, track: effects)
        }
        let graphTimeline: MotionStyleTimeline? = overlays?.graph.enabled == true
            ? motionTimeline ?? MotionStyleTimeline(points: track.map {
                CaptureMotionPoint(time: $0.time, y: $0.detected ? $0.y : nil, x: $0.detected ? $0.x : nil)
            }, touchTimes: touchTimes ?? counter?.times ?? []) : nil
        let reader = try AVAssetReader(asset: asset)
        let output: AVAssetReaderOutput
        let basic = style == .none && !usesMaterial && environment == .original
        let directSource = basic && !preserveFrameTimes
            ? try await canReadDirectly(naturalSize: videoTrack.load(.naturalSize), outputSize: size,
                transform: videoTrack.load(.preferredTransform), formats: videoTrack.load(.formatDescriptions)) : false
        if preserveFrameTimes || directSource {
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
        // A recording gap must not disguise 120/240 fps footage as low-rate MP4.
        let frameRate = Float(1 / composition.frameDuration.seconds)
        let fileType = VideoExportFormat.fileType(fps: frameRate)
        let fileExtension = VideoExportFormat.fileExtension(fps: frameRate)
        let silentURL = temp.appendingPathComponent("juggledude-render-\(UUID().uuidString).\(fileExtension)")
        let finalURL = temp.appendingPathComponent("juggledude-edited-\(UUID().uuidString).\(fileExtension)")
        var finished = false
        defer {
            try? FileManager.default.removeItem(at: silentURL)
            if !finished { try? FileManager.default.removeItem(at: finalURL) }
        }
        let writer = try AVAssetWriter(outputURL: silentURL, fileType: fileType)
        // Photos may otherwise interpret 120/240 fps exports as slow motion.
        // Keep the original timestamps and explicitly request full-speed playback.
        let playbackIntent = VideoExportFormat.playbackIntent()
        writer.metadata = [playbackIntent]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate(for: size)]])
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
        var edit = SessionEditState(style: style, intensity: intensity, ballSkin: skin, environment: environment)
        edit.ballChanges = ballChanges; edit.swapEffect = swapEffect
        let swaps = BallSwapTimeline(edit: edit, touchTimes: effects.touches)
        let needsGPU = (style != .none && intensity > 0) || environment != .original
        try await VideoWorkExecution.checkpoint(requiresGPU: needsGPU)
        let engine = needsGPU ? try MetalEffectEngine() : nil
        var ci = engine.map { CIContext(mtlDevice: $0.device, options: [.cacheIntermediates: false]) }
        let canCopyComposedPixels = !preserveFrameTimes && !needsGPU && !usesMaterial
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
                    if !(canCopyComposedPixels && copyBGRA(pixels, to: target)) {
                        if ci == nil {
                            ci = CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly, .cacheIntermediates: false])
                        }
                        var image=CIImage(cvPixelBuffer:pixels)
                        if preserveFrameTimes,image.extent.size != size {
                            image=image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:size.height/image.extent.height,
                                kCIInputAspectRatioKey:(size.width/image.extent.width)/(size.height/image.extent.height)])
                        }
                        ci?.render(image, to: target)
                    }
                    #if DEBUG
                    try PipelineParityReview.exportPixels(target, time: time, stage: "source")
                    #endif
                    if usesMaterial {
                        // The ball on screen at this frame, and the change moment if one is still playing.
                        let frameSkin = edit.ballSkin(at: time, touchTimes: effects.touches)
                        let swap = swaps.active(at: time)
                        let sample = effects.replacementGuide(at: time)
                        // Measure on the decoder's pixels, as replay and source spin do.
                        // Core Image's output color conversion can change edge scores
                        // enough to select a different outline on a blurred ball.
                        // Keep geometry in source coordinates; the normalized patch
                        // rect handles prepared scenes whose output size differs.
                        let appearanceSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                        let fitted = frameSkin == .original ? nil
                            : sample.flatMap { BallReplacementFootprint.fit(pixels: pixels, sample: $0, measureTexture: true) }
                        let smear = effects.smear(at: time, size: appearanceSize)
                        let matte = frameSkin == .original ? nil
                            : effects.replacementMatte(at: time, fitted: fitted, size: appearanceSize, smear: smear,
                                                       photographicSmear: effects.surfaceMotion?.photographicExposure != nil)
                        let footprint = effects.usesBallMasks ? matte?.footprint : fitted
                        let coverage: ((Double, Double) -> Double)? = matte.map { m in
                            { x, y in m.coverage(x: x, y: y) }
                        }
                        let background = matte.flatMap { BallReplacementBackground(pixels: pixels, matte: $0) }
                        let replacement = frameSkin == .original ? nil
                            : BallMaterialRenderer.replacement(footprint: footprint, skin: frameSkin,
                                time: time, coverage: coverage, coverageBounds: matte?.bounds,
                                orientation: effects.surfaceMotion?.renderOrientation(at: time), smear: smear,
                                light: effects.surfaceMotion?.light(at: time), background: background)
                        if replacement != nil || swap != nil {
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
                                BallMaterialRenderer.draw(in: ctx, size: size, sourceSize: appearanceSize, skin: frameSkin,
                                    sample: replacement == nil ? nil : sample, time: time, replacement: replacement,
                                    scale: swap.map { swaps.effect.ballScale(age: $0.age) } ?? 1)
                                if let swap, let guide = sample ?? effects.sample(at: time) {
                                    let geometry = BallMaterialRenderer.outputGeometry(size: size, sourceSize: appearanceSize, sample: guide)
                                    BallSwapRenderer.draw(in: ctx, center: geometry.center, radius: geometry.radius,
                                                          effect: swaps.effect, age: swap.age, event: swap.event)
                                }
                            }
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
        // A muted original keeps none of the recorded sound in the saved file.
        let audioTracks = clipAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        // Replay sounds are mixed with the clip's own audio into one track, so every
        // player hears both; most players ignore a second, parallel audio track.
        var mixedAudio: URL?
        if let soundtrack, !soundtrack.isEmpty {
            mixedAudio = try await soundtrack.mixedAudio(source: asset, duration: duration, includeSource: clipAudio)
        }
        defer { if let mixedAudio { try? FileManager.default.removeItem(at: mixedAudio) } }
        if audioTracks.isEmpty && mixedAudio == nil {
            try FileManager.default.moveItem(at: silentURL, to: finalURL)
        } else {
            let mux = AVMutableComposition()
            let rendered = AVURLAsset(url: silentURL)
            guard let renderedTrack = try await rendered.loadTracks(withMediaType: .video).first,
                  let destination = mux.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw failure("Cannot finish video.")
            }
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: renderedTrack, at: .zero)
            // The asset must outlive the insert and the export; a track whose asset was
            // released fails to insert with -12780.
            let mixedAsset = mixedAudio.map { AVURLAsset(url: $0) }
            if let mixedAsset {
                guard let audio = try await mixedAsset.loadTracks(withMediaType: .audio).first,
                      let dest = mux.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw failure("Cannot add the replay sounds.")
                }
                let range = try await audio.load(.timeRange)
                let available = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, duration: duration))
                try dest.insertTimeRange(available, of: audio, at: available.start)
            } else {
                for audio in audioTracks {
                    let range = try await audio.load(.timeRange)
                    let available = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, duration: duration))
                    guard available.duration > .zero,
                          let dest = mux.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try dest.insertTimeRange(available, of: audio, at: available.start)
                }
            }
            guard let session = AVAssetExportSession(asset: mux, presetName: AVAssetExportPresetPassthrough) else { throw failure("Cannot preserve audio.") }
            // A new composition does not inherit the writer's movie-level metadata.
            session.metadata = [playbackIntent]
            do { try await session.export(to: finalURL, as: fileType) }
            catch { try? FileManager.default.removeItem(at: finalURL); throw error }
            withExtendedLifetime(mixedAsset) {}
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: finalURL.path)
        try Task.checkCancellation()
        finished = true
        await onProgress(1)
        return finalURL
    }
}
