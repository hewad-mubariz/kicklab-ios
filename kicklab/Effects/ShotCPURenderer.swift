import CoreVideo

/// Uses the same trail and camera math as Metal when iOS grants CPU-only runtime.
nonisolated enum ShotCPURenderer {
    static func composite(_ frame: EffectFrame, pixelBuffer: CVPixelBuffer, camera: ShotCameraFrame, atlas: ShotSpriteAtlas? = nil,
                          arc: ShotArcLayers? = nil) throws {
        // Frozen Arc reads its layers where the other moves read the sprite sheet.
        let picture: (bytes: [UInt8], width: Int, height: Int)? = camera.usesArcLayers
            ? arc.map { ($0.bytes, $0.width, $0.height) }
            : atlas.map { ($0.bytes, ShotSpriteAtlas.width, ShotSpriteAtlas.height) }
        var uniforms = frame.uniforms
        let cameraUniforms = camera.uniforms(hasAtlas: picture != nil)
        let trail = frame.trail.isEmpty ? [SIMD4<Float>.zero] : frame.trail
        let path = camera.path.isEmpty ? [SIMD4<Float>.zero] : camera.path
        let stamps = camera.stamps.isEmpty ? [SIMD4<Float>.zero] : camera.stamps
        let atlasBytes = picture?.bytes ?? []
        let success = trail.withUnsafeBufferPointer { trail in
            path.withUnsafeBufferPointer { path in
                stamps.withUnsafeBufferPointer { stamps in
                    cameraUniforms.withUnsafeBufferPointer { camera in
                        atlasBytes.withUnsafeBufferPointer { atlasPixels in
                            KLRenderShotCPU(pixelBuffer, &uniforms, trail.baseAddress!, camera.baseAddress!, path.baseAddress!, stamps.baseAddress!,
                                            atlasPixels.baseAddress, Int32(picture?.width ?? 0), Int32(picture?.height ?? 0),
                                            frame.style >= 20 && frame.intensity > 0.005 && frame.visibility > 0.005, cameraUniforms[0].z > 0)
                        }
                    }
                }
            }
        }
        guard success else { throw ShotEffectExporter.Failure.writer("Cannot render this video frame.") }
    }
}
