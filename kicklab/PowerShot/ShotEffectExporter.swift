import AVFoundation
import Photos
import AudioToolbox

/// Renders the upright shot with the replay's trail, camera framing and source-clock timing.
nonisolated enum ShotEffectExporter {
    enum Failure: LocalizedError {
        case noVideo, writer(String), photos
        var errorDescription: String? {
            switch self {
            case .noVideo: "This shot has no video track."
            case .writer(let reason): "Couldn’t render the shot. \(reason)"
            case .photos: "Allow Photos access in Settings to save your shot."
            }
        }
    }

    static func render(source: URL, track: BallEffectTrack, style: ShotTrailStyle, intensity: Double = 1,
                       distance: BallDistanceTimeline? = nil, camera: ShotCameraSettings = .init(),
                       flight: ShotFlight? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        try VideoSafetyPolicy.requireExportSpace(duration: sourceDuration)
        let clock = ShotReplayClock(settings: camera, track: track, flight: flight, duration: sourceDuration)
        let asset = try await clock.asset(source: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration)
        try VideoSafetyPolicy.requireExportSpace(duration: duration.seconds)
        let composition = try await EffectVideoGeometry.composition(track: video, duration: duration, shortEdge: 1080)
        let size = composition.renderSize
        let frameRate = try await video.load(.nominalFrameRate)
        let fileType = VideoExportFormat.fileType(fps: frameRate)
        let output = URL.temporaryDirectory.appendingPathComponent("power-shot-\(UUID().uuidString).\(VideoExportFormat.fileExtension(fps: frameRate))")

        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        frames.videoComposition = composition
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw Failure.writer("Cannot decode this video.") }
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
            guard soundReader.canAdd(sound) else { throw Failure.writer("Cannot decode the source audio.") }
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
        guard writer.canAdd(picture) else { throw Failure.writer("Cannot encode this video.") }
        writer.add(picture)
        let format = try await audioTrack?.load(.formatDescriptions).first
        let audioSettings: [String: Any]? = clock.isOriginal ? nil : [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ]
        let audioInput = sound == nil ? nil : AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings,
                                                               sourceFormatHint: clock.isOriginal ? format : nil)
        if let input = audioInput {
            guard writer.canAdd(input) else { throw Failure.writer("Cannot preserve this audio format.") }
            writer.add(input)
            guard soundReader?.startReading() == true else {
                throw Failure.writer("The source audio could not be opened.")
            }
        }
        let audioRange = try await audioTrack?.load(.timeRange)
        var audioEnd: Double?
        var videoFrames = 0

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
                    guard writer.status == .writing else { throw Failure.writer(writer.error?.localizedDescription ?? "Audio encoding stopped.") }
                    try await Task.sleep(for: .milliseconds(4))
                }
                guard audioInput.append(next) else { throw Failure.writer(writer.error?.localizedDescription ?? "Couldn’t save the sound.") }
                let end = CMSampleBufferGetPresentationTimeStamp(next).seconds + CMSampleBufferGetDuration(next).seconds
                if end.isFinite { audioEnd = max(audioEnd ?? end, end) }
                pendingSound = sound?.copyNextSampleBuffer()
            }
            if pendingSound == nil {
                guard soundReader?.status == .completed else {
                    throw Failure.writer("Audio decoding stopped before it finished.")
                }
                audioInput.markAsFinished(); soundFinished = true
            }
        }
        while true {
            try await VideoWorkExecution.checkpoint(requiresGPU: engine != nil)
            guard let sample = frames.copyNextSampleBuffer() else { break }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let sourceTime = clock.sourceTime(for: time)
            let frame = EffectFrame.shot(size: size, sourceSize: size, style: style, intensity: intensity, track: track, time: sourceTime)
            let cameraFrame = ShotCameraFrame.make(settings: camera, track: track, flight: flight, size: size, time: sourceTime)
            if (frame.intensity > 0.005 && frame.visibility > 0.005) || cameraFrame.isActive {
                if let engine { try engine.composite(frame, pixelBuffer: pixels, camera: cameraFrame) }
                else { try ShotCPURenderer.composite(frame, pixelBuffer: pixels, camera: cameraFrame) }
            }
            // A recorded roll keeps its distance badge, as the earlier editor saved it.
            if let distance { try drawBadge(distance.state(at: sourceTime), on: pixels, size: size) }
            try await feedSound(through: time + 0.25)
            while !picture.isReadyForMoreMediaData {
                try await VideoWorkExecution.checkpoint(requiresGPU: engine != nil)
                guard writer.status == .writing else { throw Failure.writer(writer.error?.localizedDescription ?? "Video encoding stopped.") }
                try await Task.sleep(for: .milliseconds(4))
            }
            guard picture.append(sample) else { throw Failure.writer(writer.error?.localizedDescription ?? "Couldn’t save this frame.") }
            videoFrames += 1
            progress(min(0.98, time / total))
        }
        try await VideoWorkExecution.checkpoint()
        picture.markAsFinished()
        try await feedSound(through: .infinity)
        if !soundFinished { audioInput?.markAsFinished() }
        writer.endSession(atSourceTime: duration)
        guard reader.status == .completed, videoFrames > 0 else {
            throw Failure.writer(reader.error?.localizedDescription ?? "Video decoding did not finish.")
        }
        if let audioRange, audioRange.duration.seconds > 0 {
            let expectedEnd = min(duration.seconds, CMTimeRangeGetEnd(audioRange).seconds)
            guard let audioEnd, audioEnd >= expectedEnd - 0.1 else {
                throw Failure.writer("The source audio ended unexpectedly. Try another copy of the video.")
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
            throw Failure.writer("Cannot draw the distance badge.")
        }
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        BallDistanceBadgeRenderer.draw(in: context, size: size, state: state)
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
