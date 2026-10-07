import AVFoundation
import CoreGraphics

/// One display coordinate system for decoding, preview and exported pixels.
nonisolated enum EffectVideoGeometry {
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
    static func composition(track: AVAssetTrack, duration: CMTime, shortEdge: Int? = nil) async throws -> AVMutableVideoComposition {
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(transform).standardized
        let scale = shortEdge.map { min(1, CGFloat($0) / min(bounds.width, bounds.height)) } ?? 1
        let size = CGSize(width: max(2, floor(bounds.width * scale / 2) * 2),
                          height: max(2, floor(bounds.height * scale / 2) * 2))
        let fps = try await track.load(.nominalFrameRate)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let upright = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: size.width / bounds.width, y: size.height / bounds.height))
        layer.setTransform(upright, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        // Tone-map HDR inputs into the same SDR space used by CG effects and H.264.
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.frameDuration = CMTime(seconds: 1 / Double(fps > 0 ? fps : 30), preferredTimescale: 60_000)
        composition.instructions = [instruction]
        return composition
    }
}
