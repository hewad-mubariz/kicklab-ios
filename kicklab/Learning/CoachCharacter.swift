import SceneKit
import simd
#if canImport(UIKit)
import UIKit
private typealias CoachColor = UIColor
#else
import AppKit
private typealias CoachColor = NSColor
#endif

/// An original, faceless training mannequin. Adult proportions and tapered meshes
/// keep the silhouette readable without clothing or a borrowed character likeness.
final class CoachCharacter {
    let node = SCNNode()
    private let pelvis = SCNNode()
    private let torso = SCNNode()
    private let neck = SCNNode()
    private let head = SCNNode()
    private var limbs: [String: SCNNode] = [:]
    private var joints: [String: SCNNode] = [:]
    private var feet: [CoachSide: SCNNode] = [:]
    private var hands: [CoachSide: SCNNode] = [:]
    private var fingers: [CoachSide: [SCNNode]] = [:]
    private(set) var jointPositions: [String: SIMD3<Float>] = [:]

    init() {
        let ivory = material(CoachColor(red: 0.81, green: 0.86, blue: 0.83, alpha: 1), roughness: 0.46)
        let jointMaterial = material(CoachColor(red: 0.54, green: 0.63, blue: 0.59, alpha: 1), roughness: 0.60)
        pelvis.geometry = Self.profile([(-0.105, 0.065, 0.07), (-0.07, 0.13, 0.095), (0, 0.15, 0.105), (0.08, 0.135, 0.09), (0.105, 0.11, 0.075)])
        torso.geometry = Self.profile([(0.02, 0.12, 0.085), (0.09, 0.125, 0.085), (0.20, 0.145, 0.095),
                                       (0.33, 0.181, 0.108), (0.43, 0.196, 0.098), (0.49, 0.17, 0.082),
                                       (0.535, 0.065, 0.055)])
        neck.geometry = SCNCapsule(capRadius: 0.046, height: 0.13)
        head.geometry = Self.profile([(-0.13, 0.035, 0.04), (-0.10, 0.066, 0.068), (-0.055, 0.086, 0.085),
                                      (0.015, 0.098, 0.092), (0.075, 0.09, 0.086), (0.115, 0.065, 0.06), (0.137, 0.008, 0.008)])
        for part in [pelvis, torso, neck, head] {
            part.geometry?.firstMaterial = ivory
            node.addChildNode(part)
        }
        for side in CoachSide.allCases {
            let key = side == .left ? "left" : "right"
            // Local Y is the length axis; the update aligns each tapered limb with its joints.
            for (name, radius, endRadius): (String, Float, Float) in [
                ("thigh", 0.086, 0.055), ("calf", 0.061, 0.034),
                ("upperArm", 0.056, 0.039), ("forearm", 0.044, 0.028)
            ] {
                let part = SCNNode(geometry: Self.profile([(0, radius * 0.75, radius * 0.72),
                    (0.13, radius, radius * 0.93), (0.42, radius * 0.94, radius * 0.86),
                    (0.82, endRadius * 1.1, endRadius), (1, endRadius, endRadius * 0.94)]))
                part.geometry?.firstMaterial = ivory
                node.addChildNode(part)
                limbs[key + name] = part
            }
            for (name, radius): (String, CGFloat) in [("hip", 0.073), ("knee", 0.052), ("shoulder", 0.063), ("elbow", 0.036)] {
                let part = SCNNode(geometry: SCNSphere(radius: radius))
                part.geometry?.firstMaterial = name == "hip" || name == "shoulder" ? ivory : jointMaterial
                node.addChildNode(part)
                joints[key + name] = part
            }
            let foot = SCNNode()
            let shoe = SCNNode(geometry: SCNBox(width: 0.106, height: 0.075, length: 0.25, chamferRadius: 0.034))
            shoe.geometry?.firstMaterial = ivory
            shoe.position = SCNVector3(0, -0.055, 0.066)
            foot.addChildNode(shoe)
            let ankle = SCNNode(geometry: SCNCapsule(capRadius: 0.035, height: 0.09))
            ankle.geometry?.firstMaterial = ivory
            ankle.position = SCNVector3(0, -0.016, -0.005)
            foot.addChildNode(ankle)
            feet[side] = foot
            node.addChildNode(foot)

            let hand = SCNNode()
            let palm = SCNNode(geometry: SCNSphere(radius: 1))
            palm.scale = SCNVector3(0.036, 0.052, 0.022)
            palm.position.y = -0.04
            palm.geometry?.firstMaterial = ivory
            hand.addChildNode(palm)
            var digits: [SCNNode] = []
            for index in 0..<4 {
                let finger = SCNNode()
                finger.position = SCNVector3((Float(index) - 1.5) * 0.017, -0.075, 0.002)
                let segment = SCNNode(geometry: SCNCapsule(capRadius: 0.009, height: index == 0 || index == 3 ? 0.043 : 0.052))
                segment.position.y = -0.017
                segment.geometry?.firstMaterial = ivory
                finger.addChildNode(segment)
                hand.addChildNode(finger)
                digits.append(finger)
            }
            let thumb = SCNNode(geometry: SCNCapsule(capRadius: 0.011, height: 0.044))
            thumb.geometry?.firstMaterial = ivory
            thumb.position = SCNVector3(-side.sign * 0.034, -0.031, 0.012)
            thumb.simdEulerAngles.z = side.sign * 0.5
            hand.addChildNode(thumb)
            hands[side] = hand
            fingers[side] = digits
            node.addChildNode(hand)
        }
        update(CoachPose.sample(.touchCatch, progress: 0), time: 0, speaking: false)
    }

    func update(_ pose: CoachPose, time: Double, speaking: Bool) {
        pelvis.simdPosition = pose.pelvis
        pelvis.simdOrientation = simd_quatf(angle: pose.roll, axis: SIMD3(0, 0, 1))
        torso.simdPosition = pose.pelvis
        torso.simdOrientation = pose.torsoRotation
        neck.simdPosition = pose.pelvis + pose.torsoRotation.act(SIMD3(0, 0.55, 0))
        neck.simdOrientation = pose.torsoRotation
        head.simdPosition = pose.pelvis + pose.torsoRotation.act(SIMD3(0, 0.70, 0))
        let nod = speaking ? Float(sin(time * 3.2)) * 0.012 : 0
        head.simdOrientation = simd_quatf(angle: pose.headYaw, axis: SIMD3(0, 1, 0)) *
            simd_quatf(angle: pose.headPitch + nod, axis: SIMD3(1, 0, 0))
        jointPositions["pelvis"] = pose.pelvis
        jointPositions["head"] = head.simdPosition
        for side in CoachSide.allCases {
            let key = side == .left ? "left" : "right"
            let hip = pose.hip(side), knee = pose.knee(side), ankle = pose.foot(side).position
            let shoulder = pose.shoulder(side), wrist = pose.hand(side)
            let elbow = CoachKinematics.joint(from: shoulder, to: wrist, upper: 0.31, lower: 0.285,
                                               pole: SIMD3(side.sign * 0.8, -0.2, -0.35))
            for (name, point) in [("hip", hip), ("knee", knee), ("ankle", ankle), ("shoulder", shoulder), ("elbow", elbow), ("wrist", wrist)] {
                joints[key + name]?.simdPosition = point
                jointPositions[key + name] = point
            }
            segment(key + "thigh", from: hip, to: knee)
            segment(key + "calf", from: knee, to: ankle)
            segment(key + "upperArm", from: shoulder, to: elbow)
            segment(key + "forearm", from: elbow, to: wrist)
            feet[side]?.simdPosition = ankle
            feet[side]?.simdOrientation = pose.foot(side).rotation
            hands[side]?.simdPosition = wrist
            hands[side]?.simdOrientation = simd_quatf(angle: -side.sign * (0.30 + pose.grip * 1.27), axis: SIMD3(0, 1, 0))
            for finger in fingers[side] ?? [] { finger.simdEulerAngles.x = -0.12 - pose.grip * 0.63 }
        }
    }

    private func segment(_ key: String, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        guard let part = limbs[key] else { return }
        let direction = end - start
        part.simdPosition = start
        part.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(direction))
        part.simdScale = SIMD3(1, simd_length(direction), 1)
    }

    private func material(_ color: CoachColor, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .physicallyBased
        material.roughness.contents = roughness
        material.metalness.contents = 0.05
        return material
    }

    /// Smooth cubic interpolation between elliptical rings, with analytic surface normals.
    private static func profile(_ keys: [(Float, Float, Float)]) -> SCNGeometry {
        let rings = (keys.count - 1) * 6 + 1, sides = 32
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
        func sample(_ coordinate: Float) -> SIMD3<Float> {
            let i = min(keys.count - 2, max(0, Int(coordinate)))
            let u = min(1, max(0, coordinate - Float(i)))
            let a = keys[max(0, i - 1)], b = keys[i], c = keys[i + 1], d = keys[min(keys.count - 1, i + 2)]
            func curve(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
                0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u + (-a + 3 * b - 3 * c + d) * u * u * u)
            }
            return SIMD3(b.0 + (c.0 - b.0) * u, max(0.002, curve(a.1, b.1, c.1, d.1)), max(0.002, curve(a.2, b.2, c.2, d.2)))
        }
        for ring in 0..<rings {
            let coordinate = Float(ring) / 6
            let p = sample(coordinate)
            let lo = sample(max(0, coordinate - 0.005)), hi = sample(min(Float(keys.count - 1), coordinate + 0.005))
            for side in 0..<sides {
                let angle = Float(side) * 2 * .pi / Float(sides)
                let x = cos(angle), z = sin(angle)
                vertices.append(SCNVector3(p.y * x, p.x, p.z * z))
                let tangent = SIMD3<Float>(-p.y * z, 0, p.z * x)
                let along = SIMD3<Float>((hi.y - lo.y) * x, hi.x - lo.x, (hi.z - lo.z) * z)
                normals.append(SCNVector3(simd_normalize(simd_cross(along, tangent))))
                if ring < rings - 1 {
                    let a = Int32(ring * sides + side), b = Int32(ring * sides + (side + 1) % sides)
                    let c = a + Int32(sides), d = b + Int32(sides)
                    indices += [a, c, b, b, c, d]
                }
            }
        }
        // Flat end caps are covered by joints on limbs, but close the head/torso too.
        for (ring, sign): (Int, Float) in [(0, -1), (rings - 1, 1)] {
            let centre = Int32(vertices.count)
            vertices.append(SCNVector3(0, sample(Float(ring) / 6).x, 0))
            normals.append(SCNVector3(0, sign, 0))
            for side in 0..<sides {
                let a = Int32(ring * sides + side), b = Int32(ring * sides + (side + 1) % sides)
                indices += sign < 0 ? [centre, a, b] : [centre, b, a]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }
}
