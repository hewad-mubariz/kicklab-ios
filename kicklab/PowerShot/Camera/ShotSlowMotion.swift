import AVFoundation
import VideoToolbox

/// Smooth slow motion. The slowed stretches of a shot are rendered once with VideoToolbox's
/// machine-learning frame interpolation, so every frame of a slow-motion replay is a new picture,
/// as in a broadcast replay, instead of the same frame shown three or four times.
nonisolated final class ShotSlowMotion: @unchecked Sendable {
    /// Source seconds [from, to] played over `length` output seconds.
    struct Stretch: Hashable, Sendable {
        var from: Double
        var to: Double
        var length: Double
    }

    let source: URL
    let stretches: [Stretch]
    /// The rendered stretches, one after another in natural (unrotated) orientation, and where each
    /// one starts in it.
    let movie: URL
    let starts: [Double]

    /// Whether this device can make in-between frames (iOS 26 on recent iPhones; not the Simulator).
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        if #available(iOS 26.0, *) { VTFrameRateConversionConfiguration.isSupported }
        else { false }
        #endif
    }

    private init(source: URL, stretches: [Stretch], movie: URL, starts: [Double]) {
        self.source = source; self.stretches = stretches; self.movie = movie; self.starts = starts
    }

    /// Where a stretch sits in `movie`.
    func clip(for stretch: Stretch) -> (start: Double, length: Double)? {
        let close = { (a: Double, b: Double) in abs(a - b) < 0.000001 }
        return stretches.firstIndex { close($0.from, stretch.from) && close($0.to, stretch.to) && close($0.length, stretch.length) }
            .map { (starts[$0], stretches[$0].length) }
    }

    /// True when this render covers exactly `stretches` of `source`.
    func covers(_ stretches: [Stretch], of source: URL) -> Bool {
        source == self.source && stretches.count == self.stretches.count && stretches.allSatisfy { clip(for: $0) != nil }
    }

    /// The slowed stretches of a timeline whose blocks ask for smooth motion.
    static func stretches(in timeline: ShotEditTimeline, track: ShotCameraTrack) -> [Stretch] {
        timeline.segments.compactMap { segment in
            guard case .play(let rate) = segment.kind, rate < 0.999, let id = segment.clip,
                  track.clip(id)?.settings.smoothMotion == true, segment.to > segment.from else { return nil }
            return Stretch(from: segment.from, to: segment.to, length: segment.outputLength)
        }
    }

    enum Failure: Error { case noVideo, unreadable, unwritable }

    /// Renders `stretches` of `source` at the source's frame rate. With `interpolate: false` (tests,
    /// and devices that cannot interpolate) the in-between moments repeat the nearest frame instead.
    /// Always off the main thread: it reads, interpolates and encodes hundreds of frames.
    @concurrent static func render(source: URL, stretches: [Stretch], interpolate: Bool = true) async throws -> ShotSlowMotion? {
        guard !stretches.isEmpty else { return nil }
        if interpolate && !isAvailable { return nil }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let natural = try await track.load(.naturalSize)
        let width = Int(natural.width.rounded()), height = Int(natural.height.rounded())
        let nominal = Double(try await track.load(.nominalFrameRate))
        let fps = nominal > 1 ? nominal : 30
        var interpolator: (any FrameInterpolating)?
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *), interpolate {
            interpolator = try Interpolator(width: width, height: height)
            guard interpolator != nil else { return nil }
        }
        #endif
        let format = interpolator?.format ?? kCVPixelFormatType_32BGRA

        let movie = URL.temporaryDirectory.appendingPathComponent("slow-motion-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, Int(Double(width * height) * fps * 0.2))],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw Failure.unwritable }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.unwritable }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { writer.cancelWriting(); try? FileManager.default.removeItem(at: movie) } }

        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        guard let transfer else { throw Failure.unwritable }
        defer { VTPixelTransferSessionInvalidate(transfer) }

        var written = 0
        func append(_ picture: CVPixelBuffer) async throws {
            // The encoder takes BGRA; the interpolator works in its own (half-float) format.
            guard let pool = adaptor.pixelBufferPool else { throw Failure.unwritable }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let out, VTPixelTransferSessionTransferImage(transfer, from: picture, to: out) == noErr else { throw Failure.unwritable }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(out, withPresentationTime: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(fps.rounded()))) else {
                throw Failure.unwritable
            }
            written += 1
        }

        var starts: [Double] = []
        for stretch in stretches {
            starts.append(Double(written) / fps.rounded())
            let frames = try FrameWindow(asset: asset, track: track, format: format, sourceAttributes: interpolator?.sourceAttributes,
                                         from: stretch.from - 2 / fps, to: stretch.to + 2 / fps)
            let count = max(1, Int((stretch.length * fps.rounded()).rounded(.up)))
            var k = 0
            while k < count {
                try Task.checkCancellation()
                // Every output moment between the same two recorded frames goes to the interpolator at once.
                let s = stretch.from + (stretch.to - stretch.from) * Double(k) / fps.rounded() / stretch.length
                let (a, b) = frames.pair(at: s)
                var group: [(index: Int, phase: Float)] = []
                while k < count {
                    let t = stretch.from + (stretch.to - stretch.from) * Double(k) / fps.rounded() / stretch.length
                    guard t < b.time || a.time == b.time else { break }
                    let phase = b.time > a.time ? Float(min(1, max(0, (t - a.time) / (b.time - a.time)))) : 0
                    group.append((k, phase)); k += 1
                }
                let between = group.filter { $0.phase > 0.02 && $0.phase < 0.98 }.map(\.phase)
                var made: [Float: CVPixelBuffer] = [:]
                if let interpolator, !between.isEmpty, a.time < b.time {
                    let pictures = try await interpolator.frames(between: a, and: b, at: between)
                    for (phase, picture) in zip(between, pictures) { made[phase] = picture }
                }
                for item in group {
                    let picture = made[item.phase] ?? (item.phase >= 0.5 ? b.picture : a.picture)
                    try await append(picture)
                }
            }
        }
        input.markAsFinished()
        // The last frame lasts a frame too, so every stretch is fully covered.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(fps.rounded())))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.unwritable }
        finished = true
        return ShotSlowMotion(source: source, stretches: stretches, movie: movie, starts: starts)
    }

    /// Makes pictures between two recorded frames.
    private protocol FrameInterpolating: AnyObject {
        var format: OSType { get }
        var sourceAttributes: [String: Any]? { get }
        func frames(between a: (picture: CVPixelBuffer, time: Double), and b: (picture: CVPixelBuffer, time: Double),
                    at phases: [Float]) async throws -> [CVPixelBuffer]
    }

    #if !targetEnvironment(simulator)
    /// VideoToolbox's machine-learning frame interpolation (it does not exist in the Simulator).
    @available(iOS 26.0, *)
    private final class Interpolator: FrameInterpolating {
        private let configuration: VTFrameRateConversionConfiguration
        private let processor = VTFrameProcessor()
        private var pool: CVPixelBufferPool?

        init?(width: Int, height: Int) throws {
            guard let configuration = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
                                                                         qualityPrioritization: .normal,
                                                                         revision: VTFrameRateConversionConfiguration.defaultRevision),
                  !configuration.supportedPixelFormats.isEmpty else { return nil }
            self.configuration = configuration
            try processor.startSession(configuration: configuration)
            CVPixelBufferPoolCreate(nil, nil, configuration.destinationPixelBufferAttributes as CFDictionary, &pool)
        }
        deinit { processor.endSession() }

        var format: OSType { configuration.supportedPixelFormats[0] }
        var sourceAttributes: [String: Any]? { configuration.sourcePixelBufferAttributes }

        func frames(between a: (picture: CVPixelBuffer, time: Double), and b: (picture: CVPixelBuffer, time: Double),
                    at phases: [Float]) async throws -> [CVPixelBuffer] {
            guard let pool else { throw Failure.unwritable }
            var targets: [VTFrameProcessorFrame] = [], pictures: [CVPixelBuffer] = []
            for phase in phases {
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                let pts = CMTime(seconds: a.time + (b.time - a.time) * Double(phase), preferredTimescale: 600_000)
                guard let out, let frame = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: pts) else { throw Failure.unwritable }
                targets.append(frame); pictures.append(out)
            }
            guard let first = VTFrameProcessorFrame(buffer: a.picture, presentationTimeStamp: CMTime(seconds: a.time, preferredTimescale: 600_000)),
                  let next = VTFrameProcessorFrame(buffer: b.picture, presentationTimeStamp: CMTime(seconds: b.time, preferredTimescale: 600_000)),
                  let parameters = VTFrameRateConversionParameters(sourceFrame: first, nextFrame: next, opticalFlow: nil,
                                                                   interpolationPhase: phases, submissionMode: .random,
                                                                   destinationFrames: targets) else { throw Failure.unwritable }
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                processor.process(parameters: parameters) { _, error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
            return pictures
        }
    }
    #endif

    /// The two recorded frames around a moment, read forward through a short stretch of the video.
    /// Each frame is copied out of the reader, which recycles its own buffers.
    private final class FrameWindow {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let attributes: [String: Any]
        private(set) var previous: (picture: CVPixelBuffer, time: Double)?
        private var upcoming: (picture: CVPixelBuffer, time: Double)?

        init(asset: AVAsset, track: AVAssetTrack, format: OSType, sourceAttributes: [String: Any]?, from: Double, to: Double) throws {
            reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from), preferredTimescale: 600_000),
                                           end: CMTime(seconds: max(from + 0.01, to), preferredTimescale: 600_000))
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format,
                                                                             kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
            var attributes = sourceAttributes ?? [:]
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
            self.attributes = attributes
            guard reader.canAdd(output) else { throw Failure.unreadable }
            reader.add(output)
            guard reader.startReading() else { throw Failure.unreadable }
            previous = read()
            upcoming = read()
            guard previous != nil else { throw Failure.unreadable }
        }

        /// The last recorded frame at or before `time`, and the one after it.
        func pair(at time: Double) -> (a: (picture: CVPixelBuffer, time: Double), b: (picture: CVPixelBuffer, time: Double)) {
            while let next = upcoming, next.time <= time + 0.000001 {
                previous = next
                upcoming = read()
            }
            let a = previous!
            return (a, upcoming ?? a)
        }

        private func read() -> (picture: CVPixelBuffer, time: Double)? {
            guard let sample = output.copyNextSampleBuffer(), let source = CMSampleBufferGetImageBuffer(sample) else { return nil }
            let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
            var copy: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, CVPixelBufferGetPixelFormatType(source), attributes as CFDictionary, &copy)
            guard let copy else { return nil }
            CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(copy, [])
            defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(copy, []) }
            let planes = max(1, CVPixelBufferGetPlaneCount(source))
            for plane in 0..<planes {
                let isPlanar = CVPixelBufferIsPlanar(source)
                guard let from = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                      let to = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(copy, plane) : CVPixelBufferGetBaseAddress(copy) else { return nil }
                let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(source, plane) : height
                let a = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
                let b = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(copy, plane) : CVPixelBufferGetBytesPerRow(copy)
                for y in 0..<rows { memcpy(to + y * b, from + y * a, min(a, b)) }
            }
            CVBufferPropagateAttachments(source, copy)
            return (copy, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
    }
}
