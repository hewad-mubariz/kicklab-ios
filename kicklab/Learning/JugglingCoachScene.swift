import SwiftUI
import SceneKit
import simd

/// Original, procedural artwork. No downloaded models, textures or motion data.
/// These deliberately authored demonstrations are a prototype, not captured biomechanics.
struct CoachPose {
    var ball = SIMD3<Float>(0.15, 1.05, 0.24)
    var leftLift: Float = 0
    var rightLift: Float = 0
    var shift: Float = 0
    var held: Float = 1
    var thighLift: Float = 0
    var phase = "Ready"

    static func sample(_ motion: CoachMotion, progress raw: Double) -> CoachPose {
        let t = Float(raw - floor(raw))
        var pose = CoachPose()
        let other = motion == .otherFootCatch || motion == .otherFoot
        let side: Float = other ? -1 : 1
        func pulse(_ value: Float, _ centre: Float, _ width: Float) -> Float {
            max(0, 1 - abs(value - centre) / width)
        }
        func lift(_ u: Float, from: Float = 0.325, to: Float = 1.05, arc: Float = 0.55) -> Float {
            from + (to - from) * u + arc * 4 * u * (1 - u)
        }

        if motion.endsWithCatch {
            pose.ball.x = 0.15 * side
            pose.held = t < 0.14 || t >= 0.76 ? 1 : max(0, (t - 0.65) / 0.11)
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
                    if motion == .alternatingCatch { pose.ball.x = -0.15 + 0.30 * min(1, (t - 0.82) / 0.16) }
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
    private let body = SCNNode()
    private let torso = SCNNode()
    private let head = SCNNode()
    private let mouth = SCNNode()
    private let ball = SCNNode()
    private let ballShadow = SCNNode()
    private var upperArms: [SCNNode] = []
    private var forearms: [SCNNode] = []
    private var hands: [SCNNode] = []
    private var thighs: [SCNNode] = []
    private var shins: [SCNNode] = []
    private var socks: [SCNNode] = []
    private var shoes: [SCNNode] = []
    private var knees: [SCNNode] = []
    private var elbows: [SCNNode] = []
    private var previousSide = false
    private let lime = UIColor(red: 0.81, green: 0.97, blue: 0.32, alpha: 1)
    private let skin = UIColor(red: 0.67, green: 0.38, blue: 0.23, alpha: 1)
    private let ink = UIColor(red: 0.06, green: 0.11, blue: 0.10, alpha: 1)

    init() {
        scene.rootNode.addChildNode(body)
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.16
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 30
        camera.position = SCNVector3(2.4, 2.1, 6)
        camera.look(at: SCNVector3(0, 0.88, 0))
        scene.rootNode.addChildNode(camera)
        light(.ambient, intensity: 180, color: .white, position: SCNVector3(0, 4, 2))
        light(.omni, intensity: 430, color: UIColor(red: 1, green: 0.98, blue: 0.95, alpha: 1), position: SCNVector3(-2, 4, 4))
        light(.omni, intensity: 210, color: UIColor(red: 0.81, green: 0.94, blue: 0.85, alpha: 1), position: SCNVector3(2, 2, -3))

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

        torso.geometry = SCNCapsule(capRadius: 0.225, height: 0.61)
        torso.geometry?.firstMaterial = material(lime)
        torso.scale = SCNVector3(1, 1, 0.62)
        torso.position.y = 1.19
        body.addChildNode(torso)
        let collar = node(SCNTorus(ringRadius: 0.077, pipeRadius: 0.008), color: ink)
        collar.position.y = 1.48
        body.addChildNode(collar)
        let neck = node(SCNCylinder(radius: 0.065, height: 0.13), color: skin)
        neck.position.y = 1.51
        body.addChildNode(neck)
        let shorts = node(SCNBox(width: 0.34, height: 0.22, length: 0.23, chamferRadius: 0.07), color: ink)
        shorts.position.y = 0.91
        body.addChildNode(shorts)
        let badge = node(SCNBox(width: 0.035, height: 0.075, length: 0.008, chamferRadius: 0.006), color: ink)
        badge.position = SCNVector3(-0.095, 1.31, 0.128)
        body.addChildNode(badge)
        let stripe = node(SCNBox(width: 0.30, height: 0.018, length: 0.012, chamferRadius: 0.006), color: ink.withAlphaComponent(0.8))
        stripe.position = SCNVector3(0, 1.12, 0.14)
        body.addChildNode(stripe)

        head.position.y = 1.68
        body.addChildNode(head)
        let face = node(SCNSphere(radius: 0.147), color: skin)
        face.scale = SCNVector3(0.93, 1.12, 0.94)
        head.addChildNode(face)
        let hair = node(SCNSphere(radius: 0.151), color: ink)
        hair.scale = SCNVector3(1, 0.60, 1)
        hair.position = SCNVector3(0, 0.103, -0.012)
        head.addChildNode(hair)
        for sign: Float in [-1, 1] {
            let ear = node(SCNSphere(radius: 0.03), color: skin)
            ear.position = SCNVector3(sign * 0.137, 0, 0)
            head.addChildNode(ear)
            let eye = node(SCNSphere(radius: 0.012), color: ink)
            eye.scale.y = 0.8
            eye.position = SCNVector3(sign * 0.048, 0.016, 0.13)
            head.addChildNode(eye)
        }
        let nose = node(SCNSphere(radius: 0.024), color: skin)
        nose.position = SCNVector3(0, -0.015, 0.14)
        head.addChildNode(nose)
        mouth.geometry = SCNCapsule(capRadius: 0.008, height: 0.040)
        mouth.geometry?.firstMaterial = material(ink)
        mouth.eulerAngles.z = .pi / 2
        mouth.position = SCNVector3(0, -0.062, 0.126)
        head.addChildNode(mouth)

        for _ in 0..<2 {
            upperArms.append(limb(radius: 0.073, color: lime))
            forearms.append(limb(radius: 0.052, color: skin))
            let elbow = node(SCNSphere(radius: 0.052), color: skin)
            body.addChildNode(elbow); elbows.append(elbow)
            let hand = node(SCNSphere(radius: 0.061), color: skin)
            hand.scale = SCNVector3(0.75, 1.15, 0.75)
            body.addChildNode(hand); hands.append(hand)
            thighs.append(limb(radius: 0.092, color: ink))
            shins.append(limb(radius: 0.060, color: skin))
            let knee = node(SCNSphere(radius: 0.060), color: skin)
            body.addChildNode(knee); knees.append(knee)
            socks.append(limb(radius: 0.062, color: .white))
            let shoe = node(SCNBox(width: 0.14, height: 0.10, length: 0.29, chamferRadius: 0.047), color: .white)
            let sole = node(SCNBox(width: 0.144, height: 0.023, length: 0.295, chamferRadius: 0.011), color: lime)
            sole.position.y = -0.043
            shoe.addChildNode(sole)
            let lace = node(SCNBox(width: 0.06, height: 0.008, length: 0.07, chamferRadius: 0.004), color: ink)
            lace.position = SCNVector3(0, 0.05, 0.045)
            shoe.addChildNode(lace)
            body.addChildNode(shoe); shoes.append(shoe)
        }
        ball.geometry = SCNSphere(radius: 0.115)
        ball.geometry?.firstMaterial = material(.white)
        addBallPanels()
        scene.rootNode.addChildNode(ball)
        update(CoachPose(), time: 0, sideView: false, speaking: false)
    }

    func update(_ pose: CoachPose, time: Double, sideView: Bool, speaking: Bool) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        body.position.x = pose.shift
        let sway = Float(sin(time * 2)) * 0.009
        torso.eulerAngles.z = sway
        head.eulerAngles.x = pose.held > 0.8 ? 0.06 : 0.17
        mouth.scale.x = speaking ? 1 + Float(abs(sin(time * 16))) * 1.8 : 1
        ball.simdPosition = pose.ball
        if pose.held < 0.8 { ball.eulerAngles = SCNVector3(Float(time * 1.5), Float(time * 0.6), 0) }
        ballShadow.position = SCNVector3(pose.ball.x, 0.009, pose.ball.z)
        ballShadow.opacity = CGFloat(max(0.14, 0.48 - pose.ball.y * 0.22))
        let shadowScale = 1 + pose.ball.y * 0.3
        ballShadow.scale = SCNVector3(shadowScale, 1, shadowScale)
        for index in 0..<2 {
            let sign: Float = index == 0 ? -1 : 1
            let amount = index == 0 ? pose.leftLift : pose.rightLift
            let thigh = index == 1 ? pose.thighLift : 0
            let hip = SIMD3<Float>(sign * 0.13, 0.90, 0)
            let knee = SIMD3<Float>(sign * 0.15, 0.52 + amount * 0.7 + thigh * 0.36, 0.05 + amount + thigh * 0.23)
            let ankle = SIMD3<Float>(sign * 0.15, 0.12 + amount + thigh * 0.42, 0.025 + thigh * 0.16)
            segment(thighs[index], from: hip, to: knee)
            segment(shins[index], from: knee, to: ankle)
            knees[index].simdPosition = knee
            segment(socks[index], from: ankle, to: ankle + (knee - ankle) * 0.45)
            shoes[index].simdPosition = SIMD3<Float>(ankle.x, 0.075 + amount + thigh * 0.42, 0.13 + thigh * 0.16)
            let shoulder = SIMD3<Float>(sign * 0.21, 1.40, 0)
            let restingHand = SIMD3<Float>(sign * 0.38, 0.94, 0.18)
            let catchingHand = SIMD3<Float>(pose.ball.x - pose.shift + sign * 0.115, pose.ball.y - 0.015, pose.ball.z)
            let hand = simd_mix(restingHand, catchingHand, SIMD3<Float>(repeating: pose.held))
            let elbow = SIMD3<Float>(sign * 0.34, 1.15, 0.08 + 0.09 * pose.held)
            segment(upperArms[index], from: shoulder, to: elbow)
            segment(forearms[index], from: elbow, to: hand)
            elbows[index].simdPosition = elbow
            hands[index].simdPosition = hand
        }
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
    private func limb(radius: CGFloat, color: UIColor) -> SCNNode {
        let n = node(SCNCapsule(capRadius: radius, height: 0.4), color: color)
        body.addChildNode(n)
        return n
    }
    private func segment(_ n: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let delta = b - a
        n.simdPosition = (a + b) / 2
        (n.geometry as? SCNCapsule)?.height = CGFloat(simd_length(delta))
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta))
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
