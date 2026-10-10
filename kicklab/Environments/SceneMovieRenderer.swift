import AVFoundation
import Foundation

/// Render the complete prepared cutout with the exact camera used in preview.
/// Ball effects and the counter are added by the shared exporter afterwards.
nonisolated enum SceneMovieRenderer {
    static func validate(_ prepared: PreparedStadiumPreview) throws {
        guard prepared.duration.isFinite, prepared.sourceDuration.isFinite,
              prepared.duration > 0, prepared.duration + 0.05 >= prepared.sourceDuration,
              prepared.foreground != nil, prepared.recording != nil else {
            throw StadiumPreviewPreparer.failure("Prepare the complete clip before exporting this environment.")
        }
    }

    static func render(prepared: PreparedStadiumPreview, selection: SceneSelection,
                       onProgress: @Sendable (Double) async -> Void = { _ in }) async throws -> URL {
        try validate(prepared)
        var phase = "Opening the foreground"
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: prepared.foreground!)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw StadiumPreviewPreparer.failure("The prepared foreground is missing its video.")
            }
            let recording = prepared.recording!
            let alphaCache=try recording.losslessAlpha == true ? LosslessAlphaCache.Reader(folder:prepared.folder):nil
            guard alphaCache == nil || alphaCache?.frameCount==prepared.frames else {
                throw StadiumPreviewPreparer.failure("The cutout masks do not match this clip. Prepare it again.")
            }
            let id = UUID().uuidString
            let silent = prepared.folder.appendingPathComponent("scene-\(id)-silent.mp4")
            let destination = prepared.folder.appendingPathComponent("scene-\(id).mp4")
            let frameRate=try await video.load(.nominalFrameRate)
            let movie = try PreviewMovie(url: silent, size: prepared.size,frameRate:Double(frameRate))
            var completed = false
            defer {
                if !completed {
                    movie.cancel()
                    try? FileManager.default.removeItem(at: silent)
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            let renderer = try StadiumPreviewRenderer()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw StadiumPreviewPreparer.failure("The foreground could not be decoded.") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? StadiumPreviewPreparer.failure("Scene export could not start.") }
            defer { if reader.status == .reading { reader.cancelReading() } }
            phase = "Rendering scene frames"
            var count = 0
            while true {
                try await VideoWorkExecution.checkpoint(requiresGPU: true)
                guard let sample = output.copyNextSampleBuffer() else { break }
                try Task.checkCancellation()
                guard let source = CMSampleBufferGetImageBuffer(sample) else {
                    throw StadiumPreviewPreparer.failure("A foreground frame is missing.")
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let target = try autoreleasepool {
                    let target = try movie.buffer()
                    let alpha=try alphaCache?.frame(at:time.seconds) ?? source
                    try renderer.render(source: source, mask: alpha, output: target,
                        camera: selection.camera(in: recording, at: time.seconds), time: time.seconds,
                        scene: true, packed: true, sourceRect: recording.sourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                        environment: selection.environment, refined: recording.matteVersion == 2,separateAlpha:alphaCache != nil)
                    return target
                }
                try await movie.append(target, time: time)
                count += 1
                if count % 6 == 0 { await onProgress(min(0.97, time.seconds / prepared.duration)) }
            }
            guard reader.status == .completed, count == prepared.frames else {
                throw reader.error ?? StadiumPreviewPreparer.failure("The scene stopped before every frame was saved.")
            }
            let duration = CMTime(seconds: prepared.sourceDuration, preferredTimescale: 60_000)
            phase = "Finishing the scene video"
            try await movie.finish(duration: duration)
            phase = "Restoring the original audio"
            let audioAsset = AVURLAsset(url: prepared.original)
            let audio = try await audioAsset.loadTracks(withMediaType: .audio)
            defer { withExtendedLifetime(audioAsset) {} }
            try await StadiumPreviewPreparer.preserveAudio(silent: silent, destination: destination, audio: audio, duration: duration)
            try Task.checkCancellation()
            completed = true
            await onProgress(1)
            return destination
        } catch is CancellationError { throw CancellationError() }
        catch {
            #if DEBUG
            let details = "\(phase): \(error as NSError)"
            try? Data(details.utf8).write(to: URL.documentsDirectory.appendingPathComponent("scene-export-error.txt"))
            #endif
            throw NSError(domain: "KickLab.SceneExport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(phase) failed. \(error.localizedDescription)", NSUnderlyingErrorKey: error])
        }
    }
}
