import AVFoundation
import CoreGraphics
import CoreImage

/// One display coordinate system for decoding, preview and exported pixels.
nonisolated enum EffectVideoGeometry {
    /// Read a still through the exact replay/export decoder. Image-generator
    /// requests can use a different clock on variable-cadence recordings even
    /// with the same composition; a nearest mask must not hide that mismatch.
    static func still(asset: AVAsset, at seconds: Double, shortEdge: Int = 720) async throws -> (image: CGImage, actualTime: CMTime) {
        let task = Task.detached(priority: .userInitiated) {
            try await readStill(asset: asset, at: seconds, shortEdge: shortEdge)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func readStill(asset: AVAsset, at seconds: Double, shortEdge: Int) async throws -> (image: CGImage, actualTime: CMTime) {
        try Task.checkCancellation()
        guard seconds.isFinite, let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "KickLab.Geometry", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No video frame is available."])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await composition(track: track, duration: asset.load(.duration), shortEdge: shortEdge)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "KickLab.Geometry", code: 2) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var chosen: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            chosen = sample
            if CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) >= max(0, seconds) { break }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "KickLab.Geometry", code: 3) }
        guard let chosen, let pixels = CMSampleBufferGetImageBuffer(chosen) else {
            throw NSError(domain: "KickLab.Geometry", code: 4)
        }
        let image = CIImage(cvPixelBuffer: pixels)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(image, from: image.extent) else {
            throw NSError(domain: "KickLab.Geometry", code: 5)
        }
        try Task.checkCancellation()
        return (cg, CMSampleBufferGetPresentationTimeStamp(chosen))
    }

    static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
    }

    static func aspectFillRect(source: CGSize, destination: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: destination) }
        let scale = max(destination.width / source.width, destination.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (destination.width - size.width) / 2, y: (destination.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// AVAssetReaderTrackOutput does NOT apply preferredTransform. A composition does.
    static func composition(track: AVAssetTrack, duration: CMTime, shortEdge: Int? = nil, frameDuration: CMTime? = nil) async throws -> AVVideoComposition {
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(transform).standardized
        let scale = shortEdge.map { min(1, CGFloat($0) / min(bounds.width, bounds.height)) } ?? 1
        let size = CGSize(width: max(2, floor(bounds.width * scale / 2) * 2),
                          height: max(2, floor(bounds.height * scale / 2) * 2))
        let fps = try await track.load(.nominalFrameRate)
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        let upright = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: size.width / bounds.width, y: size.height / bounds.height))
        layer.setTransform(upright, at: .zero)
        var instruction = AVVideoCompositionInstruction.Configuration()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layer)]
        var composition = AVVideoComposition.Configuration()
        composition.renderSize = size
        // Tone-map HDR inputs into the same SDR space used by CG effects and H.264.
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.frameDuration = frameDuration ?? CMTime(seconds: 1 / Double(fps > 0 ? fps : 30), preferredTimescale: 60_000)
        composition.instructions = [AVVideoCompositionInstruction(configuration: instruction)]
        return AVVideoComposition(configuration: composition)
    }
}
