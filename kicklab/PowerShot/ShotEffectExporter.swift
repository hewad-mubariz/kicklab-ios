import AVFoundation
import Photos
import AudioToolbox

/// Renders the upright shot with the replay's trail, camera framing and source-clock timing.
nonisolated enum ShotEffectExporter {
    enum Failure: LocalizedError {
        case noVideo, writer(String), photos
        var errorDescription: String? {
            switch self {
            case .noVideo: String(localized: "This shot has no video track.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            case .writer(let reason): String(localized: "Couldn’t render the shot. \(reason)", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            case .photos: String(localized: "Allow Photos access in Settings to save your shot.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            }
        }
    }

    static func render(source: URL, track: BallEffectTrack, style: ShotTrailStyle, intensity: Double = 1,
                       distance: BallDistanceTimeline? = nil, camera: ShotCameraTrack = .init(),
                       flight: ShotFlight? = nil, atlas: ShotSpriteAtlas? = nil, arc: ShotArcLayers? = nil,
                       slowMotion: ShotSlowMotion? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let original = AVURLAsset(url: source)
        let sourceDuration = try await original.load(.duration).seconds
        try VideoSafetyPolicy.requireExportSpace(duration: sourceDuration)
        guard let sourceVideo = try await original.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let upright = EffectVideoGeometry.displaySize(naturalSize: try await sourceVideo.load(.naturalSize),
                                                      transform: try await sourceVideo.load(.preferredTransform))
        let sourceRate = Double(try await sourceVideo.load(.nominalFrameRate))
        // The same plan and clock as the preview, so the saved video matches what was edited.
        let plan = ShotCameraPlan(track: camera, ball: track, flight: flight, duration: sourceDuration,
                                  aspect: Double(upright.width / max(1, upright.height)), frameDuration: 1 / (sourceRate > 0 ? sourceRate : 30))
        let clock = plan.timeline
        // Stamps are cut from the source for exactly this plan's moments.
        let sprites = atlas?.stamps == plan.stamps ? atlas : try await ShotSpriteAtlas.build(source: source, stamps: plan.stamps)
        // Frozen Arc's layers, cut at its frozen moment.
        var layers = arc
        if let moment = plan.arcMoment, layers?.matches(moment) != true {
            layers = try await ShotArcLayers.build(source: source, ball: track, time: moment)
        }
        // Slow motion with new in-between frames, rendered now if the editor had not finished it.
        let slowed = ShotSlowMotion.stretches(in: clock, track: camera)
        var smooth = slowMotion?.covers(slowed, of: source) == true ? slowMotion : nil
        if smooth == nil, !slowed.isEmpty, ShotSlowMotion.isAvailable {
            smooth = try await ShotSlowMotion.render(source: source, stretches: slowed)
        }
        let asset = try await clock.asset(source: source, smooth: smooth)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration)
        try VideoSafetyPolicy.requireExportSpace(duration: duration.seconds)
        // A retimed composition reports its average rate (fewer frames over a longer time), so the
        // saved video keeps the source's own cadence instead: holds and slow stretches stay smooth.
        let frameRate = clock.isOriginal ? try await video.load(.nominalFrameRate) : Float(sourceRate > 0 ? sourceRate : 30)
        let composition = try await EffectVideoGeometry.composition(
            track: video, duration: duration, shortEdge: 1080,
            frameDuration: clock.isOriginal ? nil : CMTime(seconds: 1 / Double(frameRate), preferredTimescale: 60_000))
        let size = composition.renderSize
        let outputFrameRate = Float(1 / composition.frameDuration.seconds)
        let fileType = VideoExportFormat.fileType(fps: outputFrameRate)
        let output = URL.temporaryDirectory.appendingPathComponent("power-shot-\(UUID().uuidString).\(VideoExportFormat.fileExtension(fps: outputFrameRate))")

        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        frames.videoComposition = composition
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw Failure.writer(String(localized: "Cannot decode this video.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
        reader.add(frames)
        // Sound gets its own reader: two outputs of one reader can block each other.
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let soundReader = audioTrack == nil ? nil : try AVAssetReader(asset: asset)
        let sound: AVAssetReaderOutput? = audioTrack.map { audio in
            if clock.isOriginal { return AVAssetReaderTrackOutput(track: audio, outputSettings: nil) }
            let output = AVAssetReaderAudioMixOutput(audioTracks: [audio], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            output.audioTimePitchAlgorithm = .spectral
            return output
        }
        if let sound, let soundReader {
            guard soundReader.canAdd(sound) else { throw Failure.writer(String(localized: "Cannot decode the source audio.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
            soundReader.add(sound)
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.metadata = [VideoExportFormat.playbackIntent()]
        var finished = false
        defer {
            if !finished {
                if reader.status == .reading { reader.cancelReading() }
                if soundReader?.status == .reading { soundReader?.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: output)
            }
        }
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        picture.expectsMediaDataInRealTime = false
        // 600 ticks cannot represent every 240 fps timestamp. Match juggling's
        // time scale so encoding does not round frame duration/cadence.
        picture.mediaTimeScale = 60_000
        guard writer.canAdd(picture) else { throw Failure.writer(String(localized: "Cannot encode this video.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
        writer.add(picture)
        let format = try await audioTrack?.load(.formatDescriptions).first
        let audioSettings: [String: Any]? = clock.isOriginal ? nil : [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ]
        let audioInput = sound == nil ? nil : AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings,
                                                               sourceFormatHint: clock.isOriginal ? format : nil)
        if let input = audioInput {
            guard writer.canAdd(input) else { throw Failure.writer(String(localized: "Cannot preserve this audio format.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
            writer.add(input)
            guard soundReader?.startReading() == true else {
                throw Failure.writer(String(localized: "The source audio could not be opened.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            }
        }
        let audioRange = try await audioTrack?.load(.timeRange)
        var audioEnd: Double?
        var videoFrames = 0
        // Frames go in through an adaptor so retimed stretches can be filled at a steady cadence.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: picture, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])

        guard reader.startReading() else { throw Failure.writer(reader.error?.localizedDescription ?? "") }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)

        let engine = VideoWorkExecution.cpuOnly ? nil : try MetalEffectEngine()
        let total = max(0.001, duration.seconds)
        // The writer interleaves picture and sound, so feed sound up to each frame's time.
        // The moment the sound runs out, say so: otherwise the writer waits for it forever.
        var pendingSound = sound?.copyNextSampleBuffer()
        var soundFinished = audioInput == nil
        func feedSound(through time: Double) async throws {
            guard let audioInput, !soundFinished else { return }
            while let next = pendingSound, CMSampleBufferGetPresentationTimeStamp(next).seconds <= time {
                while !audioInput.isReadyForMoreMediaData {
                    try await VideoWorkExecution.checkpoint(requiresGPU: engine != nil)
                    guard writer.status == .writing else { throw Failure.writer(writer.error?.localizedDescription ?? String(localized: "Audio encoding stopped.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
                    try await Task.sleep(for: .milliseconds(4))
                }
                guard audioInput.append(next) else { throw Failure.writer(writer.error?.localizedDescription ?? String(localized: "Couldn’t save the sound.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
                let end = CMSampleBufferGetPresentationTimeStamp(next).seconds + CMSampleBufferGetDuration(next).seconds
                if end.isFinite { audioEnd = max(audioEnd ?? end, end) }
                pendingSound = sound?.copyNextSampleBuffer()
            }
            if pendingSound == nil {
                guard soundReader?.status == .completed else {
                    throw Failure.writer(String(localized: "Audio decoding stopped before it finished.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
                }
                audioInput.markAsFinished(); soundFinished = true
            }
        }
        /// A pristine copy of a decoded picture, so a held or slowed stretch can be drawn again.
        func duplicate(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
            var copy: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy) }
            guard let copy else { throw Failure.writer(String(localized: "Cannot prepare a replay frame.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
            CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(copy, [])
            defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(copy, []) }
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(copy) else {
                throw Failure.writer(String(localized: "Cannot prepare a replay frame.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            }
            let rowFrom = CVPixelBufferGetBytesPerRow(source), rowTo = CVPixelBufferGetBytesPerRow(copy)
            for y in 0..<min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(copy)) {
                memcpy(to + y * rowTo, from + y * rowFrom, min(rowFrom, rowTo))
            }
            return copy
        }
        // Holds, slow motion and rewinds arrive as long frames. Camera moves keep animating
        // through them, so those stretches are drawn at the source's own cadence.
        let step = 1 / Double(frameRate > 0 ? frameRate : 30)
        var held: (pixels: CVPixelBuffer, time: Double)?
        func fill(until end: Double) async throws {
            guard !clock.isOriginal, let last = held else { return }
            var t = last.time + step
            while t < end - step * 0.5 {
                try await draw(try duplicate(last.pixels), at: t)
                t += step
            }
        }
        func draw(_ pixels: CVPixelBuffer, at time: Double) async throws {
            let location = clock.locate(time)
            let sourceTime = location.source
            let frame = EffectFrame.shot(size: size, sourceSize: size, style: style, intensity: intensity, track: track, time: sourceTime)
            let cameraFrame = camera.isEmpty ? ShotCameraFrame(size: size) : plan.frame(location: location, size: size)
            if (frame.intensity > 0.005 && frame.visibility > 0.005) || cameraFrame.isActive {
                if let engine { try engine.composite(frame, pixelBuffer: pixels, camera: cameraFrame, atlas: sprites, arc: layers) }
                else { try ShotCPURenderer.composite(frame, pixelBuffer: pixels, camera: cameraFrame, atlas: sprites, arc: layers) }
            }
            if !cameraFrame.captions.isEmpty { try drawCaptions(cameraFrame.captions, on: pixels, size: size) }
            // A recorded roll keeps its distance badge, as the earlier editor saved it.
            if let distance { try drawBadge(distance.state(at: sourceTime), on: pixels, size: size) }
            try await feedSound(through: time + 0.25)
            while !picture.isReadyForMoreMediaData {
                try await VideoWorkExecution.checkpoint(requiresGPU: engine != nil)
                guard writer.status == .writing else { throw Failure.writer(writer.error?.localizedDescription ?? String(localized: "Video encoding stopped.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) }
                // A silent hold has no sound until it ends, and the writer can stop taking pictures
                // until it has sound to interleave: hand it the next sound early instead of waiting.
                if let audioInput, !soundFinished, audioInput.isReadyForMoreMediaData, let next = pendingSound {
                    try await feedSound(through: CMSampleBufferGetPresentationTimeStamp(next).seconds)
                    continue
                }
                try await Task.sleep(for: .milliseconds(4))
            }
            guard adaptor.append(pixels, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60_000)) else {
                throw Failure.writer(writer.error?.localizedDescription ?? String(localized: "Couldn’t save this frame.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            }
            videoFrames += 1
            progress(min(0.98, time / total))
        }
        while true {
            try await VideoWorkExecution.checkpoint(requiresGPU: engine != nil)
            guard let sample = frames.copyNextSampleBuffer() else { break }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try await fill(until: time)
            if !clock.isOriginal { held = (try duplicate(pixels), time) }
            try await draw(pixels, at: time)
        }
        try await fill(until: duration.seconds)
        try await VideoWorkExecution.checkpoint()
        picture.markAsFinished()
        try await feedSound(through: .infinity)
        if !soundFinished { audioInput?.markAsFinished() }
        writer.endSession(atSourceTime: duration)
        guard reader.status == .completed, videoFrames > 0 else {
            throw Failure.writer(reader.error?.localizedDescription ?? String(localized: "Video decoding did not finish.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        }
        if let audioRange, audioRange.duration.seconds > 0 {
            let expectedEnd = min(duration.seconds, CMTimeRangeGetEnd(audioRange).seconds)
            guard let audioEnd, audioEnd >= expectedEnd - 0.1 else {
                throw Failure.writer(String(localized: "The source audio ended unexpectedly. Try another copy of the video.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
        try Task.checkCancellation()
        finished = true
        progress(1)
        return output
    }

    private static func drawBadge(_ state: BallDistanceTimeline.Sample, on pixels: CVPixelBuffer, size: CGSize) throws {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw Failure.writer(String(localized: "Cannot draw the distance badge.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        }
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        BallDistanceBadgeRenderer.draw(in: context, size: size, state: state)
    }

    private static func drawCaptions(_ captions: [ShotCaption], on pixels: CVPixelBuffer, size: CGSize) throws {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw Failure.writer(String(localized: "Cannot draw the replay captions.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        }
        ShotCaptionRenderer.draw(captions, in: context, height: size.height)
    }

    static func authorizePhotos() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.photos }
    }

    static func saveToPhotos(_ url: URL) async throws {
        try await authorizePhotos()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
