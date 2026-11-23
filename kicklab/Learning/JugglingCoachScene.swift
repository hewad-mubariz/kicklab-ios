import SwiftUI
import SceneKit
import simd

/// Authored lesson paths retargeted onto the licensed human coach.
/// These demonstrations are a prototype, not captured biomechanics.
struct CoachPose {
    var ball = SIMD3<Float>(0.15, 1.05, 0.24)
    var leftLift: Float = 0
    var rightLift: Float = 0
    var shift: Float = 0
    var held: Float = 1
    var thighLift: Float = 0
    var phase = "Ready"
    var usesFootContact = true

    static func sample(_ motion: CoachMotion, progress raw: Double) -> CoachPose {
        let t = Float(raw - floor(raw))
        var pose = CoachPose()
        pose.usesFootContact = motion != .bounceCatch
        let other = motion == .otherFootCatch || motion == .otherFoot
        let side: Float = other ? -1 : 1
        func ease(_ value: Float) -> Float {
            let u = min(1, max(0, value))
            return u * u * (3 - 2 * u)
        }
        func pulse(_ value: Float, _ centre: Float, _ width: Float) -> Float {
            ease(1 - abs(value - centre) / width)
        }
        func lift(_ u: Float, from: Float = 0.325, to: Float = 1.05, arc: Float = 0.55) -> Float {
            from + (to - from) * u + arc * 4 * u * (1 - u)
        }

        if motion.endsWithCatch {
            pose.ball.x = 0.15 * side
            pose.held = t < 0.30 ? 1 - ease((t - 0.14) / 0.10) : ease((t - 0.65) / 0.11)
            if motion == .bounceCatch {
                pose.ball.x = 0
                if t < 0.14 { pose.phase = "Hold" }
                else if t < 0.40 {
                    let u = (t - 0.14) / 0.26
                    pose.ball.y = 1.05 - 0.935 * u * u
                    pose.phase = "Drop"
                } else if t < 0.76 {
                    pose.ball.y = lift((t - 0.40) / 0.36, from: 0.115, arc: 0.28)
                    pose.phase = "Bounce"
                } else { pose.phase = "Catch & reset" }
            } else {
                let two = motion == .twoTouchCatch || motion == .alternatingCatch
                let contact: Float = 0.34
                if t < 0.14 { pose.phase = "Hold" }
                else if t < contact {
                    let u = (t - 0.14) / (contact - 0.14)
                    pose.ball.y = 1.05 - 0.725 * u * u
                    pose.phase = "Drop"
                } else if two && t < 0.55 {
                    let u = (t - contact) / (0.55 - contact)
                    pose.ball.y = lift(u, to: 0.325, arc: 0.52)
                    if motion == .alternatingCatch { pose.ball.x = 0.15 * (1 - 2 * u) }
                    pose.phase = "First touch"
                } else if t < 0.76 {
                    let start: Float = two ? 0.55 : contact
                    pose.ball.y = lift((t - start) / (0.76 - start), arc: 0.34)
                    if motion == .alternatingCatch { pose.ball.x = -0.15 }
                    pose.phase = two ? "Second touch" : "Gentle touch"
                } else {
                    if motion == .alternatingCatch { pose.ball.x = -0.15 + 0.30 * ease((t - 0.82) / 0.16) }
                    pose.phase = "Catch & reset"
                }
                let first = 0.085 * pulse(t, contact, 0.11)
                let second: Float = two ? 0.085 * pulse(t, 0.55, 0.09) : 0
                if other { pose.leftLift = first }
                else { pose.rightLift = first + (motion == .alternatingCatch ? 0 : second) }
                if motion == .alternatingCatch { pose.leftLift = second }
            }
        } else {
            pose.held = 0
            let half = t < 0.5 ? Float(1) : Float(-1)
            let u = (t * 2).truncatingRemainder(dividingBy: 1)
            let single = motion == .otherFoot
            let amplitude: Float = motion == .lowTouches ? 0.32 : (motion == .changeHeight && t < 0.5 ? 1.02 : 0.64)
            pose.ball.x = single ? -0.15 : 0.15 * half * (1 - 2 * u)
            pose.ball.y = 0.325 + amplitude * 4 * u * (1 - u)
            let contact = max(pulse(u, 0, 0.20), pulse(u, 1, 0.20)) * 0.085
            if single { pose.leftLift = contact }
            else {
                pose.rightLift = 0.085 * max(pulse(t, 0, 0.10), pulse(t, 1, 0.10))
                pose.leftLift = 0.085 * pulse(t, 0.5, 0.10)
            }
            pose.phase = motion == .changeHeight ? (t < 0.5 ? "A higher lift" : "Settle the rhythm") : "Small, steady touches"
            if motion == .moving {
                pose.shift = 0.22 * sin(t * 2 * .pi)
                pose.ball.x += pose.shift
                pose.phase = "One small sideways step"
            }
            if motion == .thigh {
                pose.thighLift = max(0, 1 - abs(t - 0.5) / 0.28)
                pose.ball.x = 0.15
                pose.ball.y = t < 0.5 ? lift(t * 2, to: 1.09, arc: 0.46) : lift((t - 0.5) * 2, from: 1.09, to: 0.325, arc: 0.46)
                pose.rightLift = 0.085 * max(pulse(t, 0, 0.10), pulse(t, 1, 0.10))
                pose.phase = t < 0.5 ? "Foot to thigh" : "Back to your foot"
            }
        }
        return pose
    }
}

struct JugglingCoachStage: View {
    let motion: CoachMotion
    var playing = true
    var slow = false
    var sideView = false
    var speaking = false
    var showsPhase = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var started = Date()
    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var rate = 1.0

    private var shouldRun: Bool { visible && playing && scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { context in
            let seconds = elapsed + (running ? context.date.timeIntervalSince(started) * rate : 0)
            let pose = CoachPose.sample(motion, progress: seconds / motion.duration)
            ZStack(alignment: .bottom) {
                CoachSceneSurface(pose: pose, time: seconds, sideView: sideView, speaking: speaking && running)
                    .padding(.bottom, showsPhase ? 26 : 0)
                    .accessibilityHidden(true)
                if showsPhase {
                    Text(pose.phase.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.bottom, 14)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animated juggling demonstration")
        .accessibilityValue(reduceMotion ? "Animation paused for Reduce Motion. Written steps are below." : (playing ? "Playing" : "Paused"))
        .onAppear { visible = true; synchronize() }
        .onDisappear { visible = false; synchronize() }
        .onChange(of: shouldRun) { _, _ in synchronize() }
        .onChange(of: slow) { _, _ in synchronize() }
        .onChange(of: motion) { _, _ in elapsed = 0; started = Date() }
    }

    private func synchronize() {
        let now = Date()
        if running { elapsed += now.timeIntervalSince(started) * rate }
        started = now
        rate = slow ? 0.5 : 1
        running = shouldRun
    }
}

private struct CoachSceneSurface: UIViewRepresentable {
    let pose: CoachPose
    let time: Double
    let sideView: Bool
    let speaking: Bool

    func makeCoordinator() -> CoachScene { CoachScene() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(pose, time: time, sideView: sideView, speaking: speaking)
    }
    static func dismantleUIView(_ view: SCNView, coordinator: CoachScene) {
        view.isPlaying = false
        view.scene = nil
    }
}

private final class CoachScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let human: HumanCoachRig?
    private let ball = SCNNode()
    private let ballShadow = SCNNode()
    private var previousSide = false
    private let lime = UIColor(red: 0.81, green: 0.97, blue: 0.32, alpha: 1)
    private let ink = UIColor(red: 0.06, green: 0.11, blue: 0.10, alpha: 1)

    init() {
        human = HumanCoachRig.assetURL.flatMap { try? HumanCoachRig(url: $0) }
        if let human { scene.rootNode.addChildNode(human.node) }
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.10
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = -0.3
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 30
        camera.position = SCNVector3(2.4, 2.1, 6)
        camera.look(at: SCNVector3(0, 0.88, 0))
        scene.rootNode.addChildNode(camera)
        light(.ambient, intensity: 65, color: .white, position: SCNVector3(0, 4, 2))
        light(.omni, intensity: 240, color: UIColor(red: 1, green: 0.98, blue: 0.95, alpha: 1), position: SCNVector3(-2, 4, 4))
        light(.omni, intensity: 130, color: UIColor(red: 0.81, green: 0.94, blue: 0.85, alpha: 1), position: SCNVector3(2, 2, -3))

        let platform = node(SCNCylinder(radius: 0.72, height: 0.025), color: UIColor(red: 0.13, green: 0.21, blue: 0.17, alpha: 1))
        platform.position.y = -0.02
        scene.rootNode.addChildNode(platform)
        let ring = node(SCNTorus(ringRadius: 0.69, pipeRadius: 0.003), color: lime.withAlphaComponent(0.55))
        ring.position.y = 0.002
        scene.rootNode.addChildNode(ring)
        let shadow = shadowNode(width: 0.8, height: 0.5)
        shadow.position = SCNVector3(0, 0.006, 0)
        scene.rootNode.addChildNode(shadow)
        let groundBallShadow = shadowNode(width: 0.26, height: 0.26)
        ballShadow.addChildNode(groundBallShadow)
        scene.rootNode.addChildNode(ballShadow)

        ball.geometry = SCNSphere(radius: 0.115)
        ball.geometry?.firstMaterial = material(.white)
        addBallPanels()
        scene.rootNode.addChildNode(ball)
        update(CoachPose(), time: 0, sideView: false, speaking: false)
    }

    func update(_ pose: CoachPose, time: Double, sideView: Bool, speaking: Bool) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        human?.update(pose, time: time, speaking: speaking)
        let ballPosition = human?.ballPosition ?? pose.ball
        ball.simdPosition = ballPosition
        if pose.held < 0.8 { ball.eulerAngles = SCNVector3(Float(time * 1.5), Float(time * 0.6), 0) }
        ballShadow.position = SCNVector3(ballPosition.x, 0.009, ballPosition.z)
        ballShadow.opacity = CGFloat(max(0.14, 0.48 - ballPosition.y * 0.22))
        let shadowScale = 1 + ballPosition.y * 0.3
        ballShadow.scale = SCNVector3(shadowScale, 1, shadowScale)
        SCNTransaction.commit()
        if previousSide != sideView {
            previousSide = sideView
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.35
            camera.position = sideView ? SCNVector3(6, 1.8, 0.6) : SCNVector3(2.4, 2.1, 6)
            camera.look(at: SCNVector3(0, 0.88, 0))
            SCNTransaction.commit()
        }
    }

    private func material(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.8
        m.metalness.contents = 0
        return m
    }
    private func node(_ geometry: SCNGeometry, color: UIColor) -> SCNNode {
        geometry.firstMaterial = material(color)
        return SCNNode(geometry: geometry)
    }
    private func light(_ type: SCNLight.LightType, intensity: CGFloat, color: UIColor, position: SCNVector3) {
        let n = SCNNode()
        n.light = SCNLight(); n.light?.type = type
        n.light?.intensity = intensity; n.light?.color = color
        n.position = position
        scene.rootNode.addChildNode(n)
    }
    private func shadowNode(width: CGFloat, height: CGFloat) -> SCNNode {
        let texture = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { ctx in
            let colors = [UIColor.black.withAlphaComponent(0.65).cgColor, UIColor.clear.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                                            endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
        let n = SCNNode(geometry: SCNPlane(width: width, height: height))
        n.geometry?.firstMaterial?.diffuse.contents = texture
        n.geometry?.firstMaterial?.lightingModel = .constant
        n.geometry?.firstMaterial?.writesToDepthBuffer = false
        n.eulerAngles.x = -.pi / 2
        return n
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
                        points.append(SCNVector3(direction * 0.116))
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
