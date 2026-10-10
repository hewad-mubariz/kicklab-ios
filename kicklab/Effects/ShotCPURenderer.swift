import CoreVideo

/// Uses the same trail and camera math as Metal when iOS grants CPU-only runtime.
nonisolated enum ShotCPURenderer {
    static func composite(_ frame: EffectFrame, pixelBuffer: CVPixelBuffer, camera: ShotCameraFrame) throws {
        var uniforms = frame.uniforms, cameraUniforms = camera.uniforms
        let trail = frame.trail.isEmpty ? [SIMD4<Float>.zero] : frame.trail
        let path = camera.path.isEmpty ? [SIMD4<Float>.zero] : camera.path
        let success = trail.withUnsafeBufferPointer { trail in
            path.withUnsafeBufferPointer { path in
                KLRenderShotCPU(pixelBuffer, &uniforms, trail.baseAddress!, &cameraUniforms, path.baseAddress!,
                                frame.style >= 20 && frame.intensity > 0.005 && frame.visibility > 0.005, camera.isActive)
            }
        }
        guard success else { throw ShotEffectExporter.Failure.writer("Cannot render this video frame.") }
    }
}
