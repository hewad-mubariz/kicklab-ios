import SceneKit
import simd
#if canImport(UIKit)
import UIKit
private typealias StudioColor = UIColor
#else
import AppKit
private typealias StudioColor = NSColor
#endif

/// The in-app stage and the offline motion preview use the exact same scene.
final class CoachScene {
    let scene = SCNScene()
    let camera = SCNNode()
    let character = CoachCharacter()
    private let ball = SCNNode()
    private var previousSide = false
    private let ink = StudioColor(red: 0.045, green: 0.085, blue: 0.07, alpha: 1)

    init() {
        scene.rootNode.addChildNode(character.node)
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.08
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = -0.7
        camera.camera?.screenSpaceAmbientOcclusionIntensity = 0.8
        camera.camera?.screenSpaceAmbientOcclusionRadius = 0.18
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 30
        camera.position = SCNVector3(2.5, 1.9, 6)
        camera.look(at: SCNVector3(0, 0.88, 0))
        scene.rootNode.addChildNode(camera)
        light(.ambient, intensity: 40, color: .white, position: SCNVector3(0, 4, 2))
        light(.spot, intensity: 180, color: StudioColor(red: 1, green: 0.96, blue: 0.90, alpha: 1), position: SCNVector3(-2, 4, 3))
        light(.omni, intensity: 70, color: StudioColor(red: 0.71, green: 0.85, blue: 0.82, alpha: 1), position: SCNVector3(2, 3, -2))

        let surface = SCNFloor()
        surface.reflectivity = 0.07
        surface.reflectionFalloffEnd = 1.8
        surface.firstMaterial = material(StudioColor(red: 0.035, green: 0.055, blue: 0.045, alpha: 1))
        let ground = SCNNode(geometry: surface)
        ground.position.y = -0.003
        scene.rootNode.addChildNode(ground)
        for index in -10...10 {
            for axis in 0...1 {
                let line = SCNNode(geometry: SCNBox(width: axis == 0 ? 0.0015 : 8, height: 0.001,
                                                   length: axis == 0 ? 8 : 0.0015, chamferRadius: 0))
                let grid = SCNMaterial()
                grid.lightingModel = .constant
                grid.diffuse.contents = StudioColor(red: 0.14, green: 0.19, blue: 0.16, alpha: 1)
                grid.transparency = 0.50 - CGFloat(abs(index)) * 0.035
                line.geometry?.firstMaterial = grid
                line.position = SCNVector3(axis == 0 ? Float(index) * 0.4 : 0, -0.001, axis == 1 ? Float(index) * 0.4 : 0)
                line.castsShadow = false
                scene.rootNode.addChildNode(line)
            }
        }
        ball.geometry = SCNSphere(radius: CGFloat(CoachPose.ballRadius))
        ball.geometry?.firstMaterial = material(StudioColor(red: 0.82, green: 0.97, blue: 0.35, alpha: 1))
        ball.geometry?.firstMaterial?.roughness.contents = 0.45
        addBallPanels()
        scene.rootNode.addChildNode(ball)
        update(CoachPose.sample(.touchCatch, progress: 0), time: 0, sideView: false, speaking: false)
    }

    func update(_ pose: CoachPose, time: Double, sideView: Bool, speaking: Bool) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        character.update(pose, time: time, speaking: speaking)
        ball.simdPosition = pose.ball
        ball.simdEulerAngles = SIMD3(-pose.spin, 0, 0)
        SCNTransaction.commit()
        if previousSide != sideView {
            previousSide = sideView
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            camera.position = sideView ? SCNVector3(6, 1.8, 0.6) : SCNVector3(2.5, 1.9, 6)
            camera.look(at: SCNVector3(0, 0.88, 0))
            SCNTransaction.commit()
        }
    }

    private func material(_ color: StudioColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.8
        m.metalness.contents = 0
        return m
    }
    private func node(_ geometry: SCNGeometry, color: StudioColor) -> SCNNode {
        geometry.firstMaterial = material(color)
        return SCNNode(geometry: geometry)
    }
    private func light(_ type: SCNLight.LightType, intensity: CGFloat, color: StudioColor, position: SCNVector3) {
        let n = SCNNode()
        n.light = SCNLight()
        n.light?.type = type
        n.light?.intensity = intensity
        n.light?.color = color
        n.position = position
        if type == .spot {
            n.look(at: SCNVector3(0, 0.7, 0))
            n.light?.spotOuterAngle = 75
            n.light?.castsShadow = true
            n.light?.shadowRadius = 5
            n.light?.shadowMapSize = CGSize(width: 1024, height: 1024)
            n.light?.shadowSampleCount = 16
            n.light?.shadowColor = StudioColor.black.withAlphaComponent(0.65)
        }
        scene.rootNode.addChildNode(n)
    }
    private func addBallPanels() {
        let golden: Float = (1 + sqrt(5)) / 2
        for a: Float in [-1, 1] {
            for b: Float in [-golden, golden] {
                for direction in [SIMD3<Float>(0, a, b), SIMD3<Float>(a, b, 0), SIMD3<Float>(b, 0, a)] {
                    let normal = simd_normalize(direction)
                    let tangent = simd_normalize(simd_cross(normal, SIMD3<Float>(0.31, 0.77, 0.18)))
                    let bitangent = simd_cross(normal, tangent)
                    var points: [SCNVector3] = []
                    var normals: [SCNVector3] = []
                    func append(_ v: SIMD3<Float>) {
                        let direction = simd_normalize(v)
                        points.append(SCNVector3(direction * (CoachPose.ballRadius + 0.001)))
                        normals.append(SCNVector3(direction))
                    }
                    for corner in 0..<5 {
                        let a0 = Float(corner) * 2 * .pi / 5
                        let a1 = Float(corner + 1) * 2 * .pi / 5
                        let v0 = 0.34 * (cos(a0) * tangent + sin(a0) * bitangent)
                        let v1 = 0.34 * (cos(a1) * tangent + sin(a1) * bitangent)
                        for row in 0..<4 {
                            for col in 0..<(4 - row) {
                                let origin = normal + Float(row) / 4 * v0 + Float(col) / 4 * v1
                                append(origin); append(origin + v0 / 4); append(origin + v1 / 4)
                                if row + col < 3 {
                                    append(origin + v0 / 4); append(origin + (v0 + v1) / 4); append(origin + v1 / 4)
                                }
                            }
                        }
                    }
                    let indices = points.indices.map { Int32($0) }
                    let source = SCNGeometrySource(vertices: points)
                    let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
                    let geometry = SCNGeometry(sources: [source, SCNGeometrySource(normals: normals)], elements: [element])
                    let panel = node(geometry, color: ink)
                    panel.geometry?.firstMaterial?.isDoubleSided = true
                    ball.addChildNode(panel)
                }
            }
        }
    }
}
