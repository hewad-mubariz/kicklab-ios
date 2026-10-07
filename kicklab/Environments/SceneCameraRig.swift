import CoreGraphics
import Foundation
import simd

/// A calibrated source camera plus a small virtual move. The subject plane and
/// world are projected by the same camera, so a dolly does not slide the feet.
/// This is 2.5D reprojection; it cannot reveal unseen sides of the recorded body.
nonisolated struct SceneCameraRig: Sendable, Codable {
    struct Pose: Sendable {
        var eye: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
    }
    var aspect: Float
    var verticalFOV: Float = 54 * .pi / 180
    var horizon: Float = 0.48
    var subjectHeight: Float
    var ground: SIMD2<Float>
    var movement: Float = 1
    var stadiumFraming = false
    /// Measured rotational approximation from the source background, radians.
    var recordedPan = SIMD2<Float>.zero
    /// Look around from the camera position, not an orbit through the flat body.
    var look = SIMD2<Float>.zero
    var zoom: Float = 1
    var followRecordedCamera = true
    /// Per-frame visible support point. Changes foreground depth, never the
    /// scene camera's height, so a foot adjustment cannot bob the stadium.
    var contact: VisibleFootContact?

    var tanHalfFOV: Float { tan(verticalFOV / 2) }
    var distance: Float { 1.75 / (max(0.12, subjectHeight) * 2 * tanHalfFOV) }
    var eyeHeight: Float { (ground.y - horizon) * 2 * tanHalfFOV * distance }
    var anchorX: Float { (ground.x - 0.5) * 2 * tanHalfFOV * aspect * distance }
    var subjectDistance: Float {
        guard let contact, contact.point.y > horizon + 0.05 else { return distance }
        let ray=sourceRay(contact.point)
        guard ray.y < -0.025 else { return distance }
        return min(distance * 2, max(distance * 0.5,eyeHeight*ray.z/ray.y))
    }
    var subjectZ: Float { distance - subjectDistance }
    var support: SIMD3<Float> { worldPoint(sourceUV: contact?.point ?? ground) }
    var supportWidth: Float {
        max(0.07, min(0.32, (contact?.width ?? 0.035) * 2 * tanHalfFOV * aspect * subjectDistance))
    }

    func pose(at time: Double) -> Pose {
        let t = Float(max(0, time))
        // Starts at rest with zero velocity; no frame-to-frame integration or
        // random camera shake. Slow lateral drift and a restrained forward move.
        let m = max(0, min(1, movement))
        let viewDistance=stadiumFraming ? min(distance,1.75/(0.46*2*tanHalfFOV)):distance
        let height=stadiumFraming ? (0.84-horizon)*2*tanHalfFOV*viewDistance:eyeHeight
        let eye = SIMD3<Float>((stadiumFraming ? anchorX:0)+(1-cos(t*0.35))*0.08*m,
            height + pow(sin(t*0.30), 2)*0.015*m,
            viewDistance - (1-cos(t*0.25))*0.12*m)
        let baseForward=simd_normalize(SIMD3<Float>(stadiumFraming ? anchorX:0,height,0)-eye)
        let yaw=(followRecordedCamera ? recordedPan.x:0)+look.x
        let pitch=(followRecordedCamera ? recordedPan.y:0)+look.y
        let forward=Self.rotated(baseForward,yaw:yaw,pitch:pitch)
        let right=simd_normalize(simd_cross(forward,SIMD3<Float>(0,1,0)))
        return Pose(eye:eye,right:right,up:simd_cross(right,forward),forward:forward)
    }

    var viewTanHalfFOV: Float { tanHalfFOV/max(0.8,min(1.5,zoom)) }
    var sourceBasis: Pose {
        let f=Self.rotated(SIMD3(0,0,-1),yaw:recordedPan.x,pitch:recordedPan.y)
        let r=simd_normalize(simd_cross(f,SIMD3(0,1,0)))
        return Pose(eye:SIMD3(0,eyeHeight,distance),right:r,up:simd_cross(r,f),forward:f)
    }
    private static func rotated(_ v:SIMD3<Float>,yaw:Float,pitch:Float)->SIMD3<Float> {
        let p=SIMD3(v.x,cos(pitch)*v.y-sin(pitch)*v.z,sin(pitch)*v.y+cos(pitch)*v.z)
        return SIMD3(cos(yaw)*p.x+sin(yaw)*p.z,p.y,-sin(yaw)*p.x+cos(yaw)*p.z)
    }
    private func sourceRay(_ uv:SIMD2<Float>)->SIMD3<Float> {
        let b=sourceBasis
        return b.forward+b.right*((uv.x-0.5)*2*tanHalfFOV*aspect)+b.up*((horizon-uv.y)*2*tanHalfFOV)
    }

    func worldPoint(sourceUV uv: SIMD2<Float>) -> SIMD3<Float> {
        let ray=sourceRay(uv)
        return sourceBasis.eye+ray*(-subjectDistance/min(-0.01,ray.z))
    }

    func project(_ point: SIMD3<Float>, at time: Double) -> SIMD2<Float> {
        let pose = pose(at: time), delta = point-pose.eye
        let z = simd_dot(delta, pose.forward)
        return SIMD2(0.5+simd_dot(delta,pose.right)/(z*2*viewTanHalfFOV*aspect),
            horizon-simd_dot(delta,pose.up)/(z*2*viewTanHalfFOV))
    }
}
