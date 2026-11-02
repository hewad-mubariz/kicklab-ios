import CoreGraphics
import simd

/// The ball as the Effects Lab's footage renders saw it: the app's own effect-frame position,
/// radius and visibility on a 30 Hz grid, interpolated between grid points. Lab effects that
/// remember where the ball was at a touch read it through this, so they match the accepted videos.
nonisolated struct LabBallSampler {
    let track: BallEffectTrack
    let size: CGSize
    let crop: CGRect

    init(track: BallEffectTrack, size: CGSize, sourceSize: CGSize) {
        self.track = track
        self.size = size
        crop = EffectVideoGeometry.aspectFillRect(source: sourceSize, destination: size)
    }

    /// (x, y, radius, visibility) in output pixels; an untracked moment is invisible at the centre.
    private func grid(_ index: Int) -> SIMD4<Float> {
        guard let s = track.sample(at: Double(index) / 30) else {
            return SIMD4(Float(size.width / 2), Float(size.height / 2), 1, 0)
        }
        return SIMD4(Float(crop.minX + s.center.x * crop.width), Float(crop.minY + s.center.y * crop.height),
                     Float(max(1, s.pixelRadius(in: crop.size))), Float(s.visibility))
    }

    func callAsFunction(_ time: Float) -> SIMD4<Float> {
        guard time >= 0 else { return .zero }
        let slot = time * 30, index = Int(floor(slot)), f = slot - Float(index)
        let a = grid(index), b = grid(index + 1)
        return SIMD4(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f, min(a.w, b.w))
    }
}
