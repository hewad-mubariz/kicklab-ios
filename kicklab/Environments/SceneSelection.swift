import Foundation
import simd

/// The chosen room and camera framing travel with the edit, including export.
nonisolated struct SceneSelection: Hashable, Codable, Sendable {
    var environment: PreviewEnvironment
    var look = SIMD2<Float>.zero
    var zoom: Float = 1
    var followRecordedCamera = true

    func camera(in recording: StadiumSceneRecording, at time: Double) -> SceneCameraRig {
        var camera = recording.sample(at: time)
        camera.look = SIMD2(look.x.isFinite ? look.x : 0, look.y.isFinite ? max(-0.65, min(0.65, look.y)) : 0)
        camera.zoom = zoom.isFinite ? max(0.85, min(1.3, zoom)) : 1
        camera.followRecordedCamera = followRecordedCamera
        return camera
    }

    /// Effect tracking must follow the same foreground plane as the scene shader.
    func project(_ frames: [RecordedFrame], in recording: StadiumSceneRecording) -> [RecordedFrame] {
        frames.map { frame in
            let camera = camera(in: recording, at: frame.time)
            let pose = camera.pose(at: frame.time)
            func point(_ x: Double, _ y: Double) -> SIMD2<Float>? {
                let world = camera.worldPoint(sourceUV: SIMD2(Float(x), Float(y)))
                guard simd_dot(world - pose.eye, pose.forward) > 0.01 else { return nil }
                let p = camera.project(world, at: frame.time)
                return p.x.isFinite && p.y.isFinite ? p : nil
            }
            let center = point(frame.x, frame.y)
            let corners = [-1.0, 1.0].flatMap { x in
                [-1.0, 1.0].compactMap { y in point(frame.x + x * frame.width / 2, frame.y + y * frame.height / 2) }
            }
            let width = corners.map(\.x).max().map { $0 - (corners.map(\.x).min() ?? $0) } ?? 0
            let height = corners.map(\.y).max().map { $0 - (corners.map(\.y).min() ?? $0) } ?? 0
            let valid = center != nil && corners.count == 4 && width > 0 && height > 0 && width < 2 && height < 2
            let smooth = point(frame.smoothedX, frame.smoothedY) ?? center ?? .zero
            return RecordedFrame(time: frame.time, x: Double(center?.x ?? 0), y: Double(center?.y ?? 0),
                width: Double(width), height: Double(height), score: valid ? frame.score : 0,
                smoothedX: Double(smooth.x), smoothedY: Double(smooth.y), vy: frame.vy,
                motion: frame.motion, detected: valid && frame.detected, person: nil)
        }
    }
}

nonisolated struct ScenePlayback: Sendable {
    let url: URL
    let track: [RecordedFrame]
}
