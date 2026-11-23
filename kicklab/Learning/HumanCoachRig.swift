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
        let required = ["Bip01", "Bip01_Head", "Bip01_MJaw"] + ["L", "R"].flatMap { side in
            ["Thigh", "Calf", "Foot", "Toe0", "UpperArm", "Forearm", "Hand", "Finger2"].map { "Bip01_\(side)_\($0)" }
        }
        guard required.allSatisfy({ bones[$0] != nil }) else { throw LoadError.missingSkeleton }
    }

    func update(_ pose: CoachPose, time: Double, speaking: Bool) {
        // Reset before solving so the pose is deterministic, including seeking and looping.
        for (bone, transform) in rest { bone.simdTransform = transform }
        let breathing = Float(sin(time * 1.5)) * 0.002
        let balance = (pose.leftLift - pose.rightLift) * 0.25
        if let root = bones["Bip01"], let position = worldPositions["Bip01"] {
            root.simdWorldPosition = position + SIMD3(pose.shift + balance, 0.075 + breathing, 0)
        }

        for (side, sign): (String, Float) in [("L", 1), ("R", -1)] {
            let lift = sign > 0 ? pose.rightLift : pose.leftLift
            let thigh = sign > 0 ? pose.thighLift : 0
            let ankle = SIMD3<Float>(sign * 0.15 + pose.shift, 0.105 + lift + thigh * 0.42, 0.015 + thigh * 0.18)
            solve(upper: "Bip01_\(side)_Thigh", lower: "Bip01_\(side)_Calf", end: "Bip01_\(side)_Foot",
                  target: ankle, pole: SIMD3(0, 0, 1))
            // Preserve a planted boot's original orientation rather than allowing IK to
            // rotate it with the shin. The small toe lift follows the demonstration.
            if let foot = bones["Bip01_\(side)_Foot"], let rotation = worldRotations["Bip01_\(side)_Foot"] {
                foot.simdWorldOrientation = simd_quatf(angle: -lift * 0.65, axis: SIMD3(1, 0, 0)) * rotation
            }
        }

        // Adapt the low end of the authored ball path to this model's actual laces.
        // The correction fades out near the hands, preserving drop/catch continuity.
        let mix = min(1, max(0, (pose.ball.x - pose.shift + 0.15) / 0.30))
        let rightContact = contactPoint("R", lift: pose.leftLift, thigh: 0)
        let leftContact = contactPoint("L", lift: pose.rightLift, thigh: pose.thighLift)
        let reference = simd_mix(rightContact, leftContact, SIMD3(repeating: mix))
        let amount = min(1, max(0, (1.05 - pose.ball.y) / (1.05 - 0.325)))
        let delta = reference - SIMD3(pose.ball.x, 0.24, 0.24)
        ballPosition = pose.ball + (pose.usesFootContact ? delta * amount : .zero)
        if pose.thighLift > 0, let hip = bones["Bip01_L_Thigh"], let knee = bones["Bip01_L_Calf"] {
            let thighContact = hip.simdWorldPosition * 0.3 + knee.simdWorldPosition * 0.7 + SIMD3<Float>(0, 0.19, 0.03)
            let blend = pow(pose.thighLift, 3)
            ballPosition = simd_mix(ballPosition, thighContact, SIMD3(repeating: blend))
        }

        for (side, sign): (String, Float) in [("L", 1), ("R", -1)] {
            let resting = SIMD3<Float>(sign * 0.30 + pose.shift + balance, 0.86 + breathing, 0.12)
            let catching = ballPosition + SIMD3<Float>(sign * 0.17, 0.025, 0.01)
            let hand = simd_mix(resting, catching, SIMD3(repeating: pose.held))
            solve(upper: "Bip01_\(side)_UpperArm", lower: "Bip01_\(side)_Forearm", end: "Bip01_\(side)_Hand",
                  target: hand, pole: SIMD3(sign, -0.3, -0.4))
            let relaxed = SIMD3<Float>(sign * 0.012, -0.085, 0.025)
            let grip = SIMD3<Float>(-sign * 0.07, -0.055, 0.025)
            aim("Bip01_\(side)_Hand", child: "Bip01_\(side)_Finger2",
                direction: simd_mix(relaxed, grip, SIMD3(repeating: pose.held)))
        }
        if let head = bones["Bip01_Head"], let rotation = worldRotations["Bip01_Head"] {
            head.simdWorldOrientation = simd_quatf(angle: pose.held > 0.8 ? 0.08 : 0.16, axis: SIMD3(1, 0, 0)) * rotation
        }
        if speaking, let jaw = bones["Bip01_MJaw"] {
            let opening = 0.035 + 0.045 * Float(abs(sin(time * 13)))
            jaw.simdWorldOrientation = simd_quatf(angle: opening, axis: SIMD3(1, 0, 0)) * jaw.simdWorldOrientation
        }
    }

    func position(of joint: String) -> SIMD3<Float>? { bones[joint]?.simdWorldPosition }

    private func contactPoint(_ side: String, lift: Float, thigh: Float) -> SIMD3<Float> {
        guard let ankle = bones["Bip01_\(side)_Foot"], let toe = bones["Bip01_\(side)_Toe0"] else { return .zero }
        // A football's centre sits above the instep, not at the ankle joint.
        var point = ankle.simdWorldPosition * 0.45 + toe.simdWorldPosition * 0.55
        point += SIMD3(0, 0.15 - lift - thigh * 0.42, 0.055)
        return point
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
