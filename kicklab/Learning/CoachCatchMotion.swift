import Foundation
import simd

/// Arm, wrist and finger rotations from the app's existing Mixamo low catch.
/// Keep the capture's joint articulation while IK adapts it to each lesson's ball.
struct CoachCatchMotion: Decodable {
    struct Clip: Decodable {
        let fps: Float
        let frames: [[[Float]]]

        func rotations(at time: Float) -> [simd_quatf] {
            let frame = min(Float(frames.count - 1), max(0, time * fps))
            let first = Int(frame), next = min(first + 1, frames.count - 1)
            return zip(frames[first], frames[next]).map { a, b in
                simd_slerp(simd_quatf(vector: SIMD4(a)), simd_quatf(vector: SIMD4(b)), frame - Float(first))
            }
        }
    }
    let names: [String]
    let clips: [String: Clip]

    func rotations(readiness: Float, grip: Float) -> [(String, simd_quatf)] {
        guard let ready = clips["ready"], let low = clips["low"] else { return [] }
        let neutral = ready.rotations(at: 0)
        let catchPose = low.rotations(at: 0.50 + readiness * 0.48)
        let fingers = low.rotations(at: 0.65 + grip * 0.33)
        return names.indices.map {
            let target = names[$0].contains("Finger") ? fingers[$0] : catchPose[$0]
            return (names[$0], simd_slerp(neutral[$0], target, readiness))
        }
    }
}
