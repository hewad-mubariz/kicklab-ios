import Foundation
import SceneKit
import simd

/// The licensed Rocketbox mesh supplies the anatomy, skinning and textures.
/// Lesson motion is authored here; none of the asset's embedded goalkeeper clips play.
final class HumanCoachRig {
    enum LoadError: Error { case missingSkeleton }
    let node = SCNNode()
    private var bones: [String: SCNNode] = [:]
    private var rest: [(SCNNode, simd_float4x4)] = []
    private var worldPositions: [String: SIMD3<Float>] = [:]
    private var worldRotations: [String: simd_quatf] = [:]
    private(set) var ballPosition = SIMD3<Float>(0.15, 1.05, 0.24)

    static var assetURL: URL? {
        guard let bundleURL = Bundle.main.url(forResource: "CoachAssets", withExtension: "bundle"),
              let assets = Bundle(url: bundleURL) else { return nil }
        return assets.url(forResource: "HumanCoach", withExtension: "usdz")
    }

    init(url: URL) throws {
        let scene = try SCNScene(url: url, options: nil)
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            node.addChildNode(child)
        }
        node.enumerateChildNodes { child, _ in
            child.removeAllAnimations()
            if let name = child.name, name.hasPrefix("Bip01") {
                self.bones[name] = child
                self.rest.append((child, child.simdTransform))
                self.worldPositions[name] = child.simdWorldPosition
                self.worldRotations[name] = child.simdWorldOrientation
            }
            for material in child.geometry?.materials ?? [] {
                material.lightingModel = .physicallyBased
                material.roughness.contents = 0.88
                material.metalness.contents = 0
                material.emission.intensity = 0
            }
        }
        let required = ["Bip01", "Bip01_Pelvis", "Bip01_Spine", "Bip01_Head", "Bip01_MJaw"] + ["L", "R"].flatMap { side in
            ["Thigh", "Calf", "Foot", "Toe0", "UpperArm", "Forearm", "Hand", "Finger1", "Finger2", "Finger4"].map { "Bip01_\(side)_\($0)" }
        }
        guard required.allSatisfy({ bones[$0] != nil }) else { throw LoadError.missingSkeleton }
    }

    func update(_ pose: CoachPose, time: Double, speaking: Bool) {
        for (bone, transform) in rest { bone.simdTransform = transform }
        if let root = bones["Bip01"], let restRoot = worldPositions["Bip01"], let restPelvis = worldPositions["Bip01_Pelvis"] {
            root.simdWorldPosition = restRoot + pose.pelvis - restPelvis
        }
        orient("Bip01_Pelvis", delta: simd_quatf(angle: pose.roll, axis: SIMD3(0, 0, 1)))
        orient("Bip01_Spine", delta: pose.torsoRotation)

        for side in CoachSide.allCases {
            let label = side == .right ? "L" : "R"
            let prefix = "Bip01_\(label)_"
            let foot = pose.foot(side)
            solve(upper: prefix + "Thigh", lower: prefix + "Calf", end: prefix + "Foot",
                  target: foot.position, pole: SIMD3(side.sign * 0.08, 0, 1))
            // The source goalkeeper stands toe-out. Align each boot with the forward
            // juggling axis before applying the authored toe lift.
            if let restAnkle = worldPositions[prefix + "Foot"], let restToe = worldPositions[prefix + "Toe0"] {
                let forward = restToe - restAnkle
                let straighten = simd_quatf(angle: -atan2(forward.x, forward.z), axis: SIMD3(0, 1, 0))
                orient(prefix + "Foot", delta: foot.rotation * straighten)
            }
            solve(upper: prefix + "UpperArm", lower: prefix + "Forearm", end: prefix + "Hand",
                  target: pose.hand(side), pole: SIMD3(side.sign * 0.35, -0.75, -0.25))
            poseHand(prefix, side: side, grip: pose.grip, readiness: pose.handReadiness)
        }
        orient("Bip01_Head", delta: simd_quatf(angle: pose.headYaw, axis: SIMD3(0, 1, 0)) *
               simd_quatf(angle: pose.headPitch * 0.65, axis: SIMD3(1, 0, 0)))
        if speaking, let jaw = bones["Bip01_MJaw"] {
            let opening = 0.018 * Float(abs(sin(time * 11)))
            jaw.simdWorldOrientation = simd_quatf(angle: opening, axis: SIMD3(1, 0, 0)) * jaw.simdWorldOrientation
        }
        ballPosition = pose.ball
    }

    func position(of joint: String) -> SIMD3<Float>? { bones[joint]?.simdWorldPosition }

    private func orient(_ name: String, delta: simd_quatf) {
        if let bone = bones[name], let rotation = worldRotations[name] {
            bone.simdWorldOrientation = delta * rotation
        }
    }

    private func poseHand(_ prefix: String, side: CoachSide, grip: Float, readiness: Float) {
        guard let wrist = worldPositions[prefix + "Hand"], let middle = worldPositions[prefix + "Finger2"],
              let index = worldPositions[prefix + "Finger1"], let little = worldPositions[prefix + "Finger4"] else { return }
        let restForward = simd_normalize(middle - wrist)
        let restNormal = -side.sign * simd_normalize(simd_cross(index - little, restForward))
        let restAcross = simd_normalize(simd_cross(restForward, restNormal))
        let restFrame = simd_quatf(simd_float3x3(columns: (restAcross, restForward, restNormal)))
        let openNormal = simd_normalize(SIMD3<Float>(-side.sign * 0.65, 0, 1))
        let catchNormal = simd_normalize(SIMD3<Float>(-side.sign, 0.25, 0))
        let normal = simd_normalize(simd_mix(openNormal, catchNormal, SIMD3(repeating: readiness)))
        let direction = simd_mix(SIMD3<Float>(0, -1, 0.10), SIMD3<Float>(0, 0.22, 1), SIMD3(repeating: readiness))
        let forward = simd_normalize(direction - normal * simd_dot(direction, normal))
        let across = simd_normalize(simd_cross(forward, normal))
        let frame = simd_quatf(simd_float3x3(columns: (across, forward, normal)))
        orient(prefix + "Hand", delta: frame * restFrame.inverse)
        // Curl the actual finger joints; palm orientation is controlled separately
        // so the wrists do not twist as the arms extend to receive the ball.
        for finger in 1...4 {
            for (suffix, angle): (String, Float) in [("", 0.10 + 0.25 * grip), ("1", 0.36 * grip), ("2", 0.18 * grip)] {
                if let bone = bones[prefix + "Finger\(finger)" + suffix] {
                    bone.simdWorldOrientation = simd_quatf(angle: angle, axis: across) * bone.simdWorldOrientation
                }
            }
        }
        if let thumb = bones[prefix + "Finger01"] {
            thumb.simdWorldOrientation = simd_quatf(angle: 0.18 * grip, axis: across) * thumb.simdWorldOrientation
        }
    }

    private func solve(upper: String, lower: String, end: String, target: SIMD3<Float>, pole: SIMD3<Float>) {
        guard let a = bones[upper], let b = bones[lower], let c = bones[end] else { return }
        let origin = a.simdWorldPosition
        let lengthA = simd_distance(origin, b.simdWorldPosition)
        let lengthB = simd_distance(b.simdWorldPosition, c.simdWorldPosition)
        let delta = target - origin
        let distance = min(lengthA + lengthB - 0.001, max(abs(lengthA - lengthB) + 0.001, simd_length(delta)))
        let direction = simd_normalize(delta)
        var bend = pole - direction * simd_dot(pole, direction)
        if simd_length_squared(bend) < 0.001 { bend = simd_cross(direction, SIMD3(1, 0, 0)) }
        bend = simd_normalize(bend)
        let along = (lengthA * lengthA - lengthB * lengthB + distance * distance) / (2 * distance)
        let height = sqrt(max(0, lengthA * lengthA - along * along))
        let elbow = origin + direction * along + bend * height
        aim(upper, child: lower, direction: elbow - origin)
        aim(lower, child: end, direction: origin + direction * distance - b.simdWorldPosition)
    }

    private func aim(_ name: String, child: String, direction: SIMD3<Float>) {
        guard let bone = bones[name], let end = bones[child] else { return }
        let current = end.simdWorldPosition - bone.simdWorldPosition
        guard simd_length_squared(current) > 0.000001, simd_length_squared(direction) > 0.000001 else { return }
        bone.simdWorldOrientation = simd_quatf(from: simd_normalize(current), to: simd_normalize(direction)) * bone.simdWorldOrientation
    }
}
