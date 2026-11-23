import Foundation
import simd

enum CoachSide: CaseIterable {
    case left, right
    var sign: Float { self == .left ? -1 : 1 }
}

struct CoachFoot {
    var position: SIMD3<Float>
    var pitch: Float = 0
    var rotation: simd_quatf { simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) }
    var ballContact: SIMD3<Float> {
        position + rotation.act(SIMD3(0, 0.035, 0.13)) + SIMD3(0, CoachPose.ballRadius, 0)
    }
}

/// World-space choreography. Gravity, contacts, weight transfer and hand preparation
/// share one clock, so slow playback slows the entire demonstration consistently.
struct CoachPose {
    static let ballRadius: Float = 0.105
    var ball = SIMD3<Float>(0.145, 1.10, 0.28)
    var pelvis = SIMD3<Float>(0, 0.96, -0.025)
    var lean: Float = 0.06
    var roll: Float = 0
    var twist: Float = 0
    var leftFoot = CoachFoot(position: SIMD3(-0.145, 0.095, 0))
    var rightFoot = CoachFoot(position: SIMD3(0.145, 0.095, 0))
    var leftHand = SIMD3<Float>(0.005, 1.16, 0.28)
    var rightHand = SIMD3<Float>(0.285, 1.16, 0.28)
    var held: Float = 1
    var grip: Float = 1
    var headPitch: Float = 0.16
    var headYaw: Float = 0
    var spin: Float = 0
    var phase = "Ready"

    func foot(_ side: CoachSide) -> CoachFoot { side == .left ? leftFoot : rightFoot }
    func hand(_ side: CoachSide) -> SIMD3<Float> { side == .left ? leftHand : rightHand }
    var torsoRotation: simd_quatf {
        simd_quatf(angle: twist, axis: SIMD3(0, 1, 0)) *
        simd_quatf(angle: -roll * 0.45, axis: SIMD3(0, 0, 1)) *
        simd_quatf(angle: lean, axis: SIMD3(1, 0, 0))
    }
    func hip(_ side: CoachSide) -> SIMD3<Float> {
        pelvis + simd_quatf(angle: roll, axis: SIMD3(0, 0, 1)).act(SIMD3(side.sign * 0.09, 0, 0))
    }
    func shoulder(_ side: CoachSide) -> SIMD3<Float> {
        pelvis + torsoRotation.act(SIMD3(side.sign * 0.205, 0.49, 0))
    }
    func knee(_ side: CoachSide) -> SIMD3<Float> {
        CoachKinematics.joint(from: hip(side), to: foot(side).position, upper: 0.445, lower: 0.435,
                              pole: SIMD3(side.sign * 0.08, 0, 1))
    }
    static func sample(_ motion: CoachMotion, progress: Double) -> CoachPose {
        let choreography = CoachChoreography(motion)
        return choreography.sample(seconds: Float(progress - floor(progress)) * choreography.duration)
    }
}

enum CoachKinematics {
    /// Analytic two-link solve; the renderer never stretches a limb to reach a target.
    static func joint(from origin: SIMD3<Float>, to target: SIMD3<Float>, upper: Float, lower: Float,
                      pole: SIMD3<Float>) -> SIMD3<Float> {
        let delta = target - origin
        let distance = min(upper + lower - 0.0001, max(abs(upper - lower) + 0.0001, simd_length(delta)))
        let direction = simd_normalize(delta)
        var bend = pole - direction * simd_dot(pole, direction)
        if simd_length_squared(bend) < 0.0001 { bend = simd_cross(direction, SIMD3(1, 0, 0)) }
        bend = simd_normalize(bend)
        let along = (upper * upper - lower * lower + distance * distance) / (2 * distance)
        return origin + direction * along + bend * sqrt(max(0, upper * upper - along * along))
    }
}

struct CoachChoreography {
    enum ContactKind { case foot, thigh, floor }
    struct Contact {
        let time: Float
        let side: CoachSide
        var offset: Float = 0
        var kind: ContactKind = .foot
    }
    static let gravity: Float = 9.81
    let motion: CoachMotion
    let contacts: [Contact]
    let duration: Float
    let release: Float
    let catchTime: Float?
    private let catchHeight: Float

    init(_ motion: CoachMotion) {
        self.motion = motion
        let side: CoachSide = motion == .otherFootCatch || motion == .otherFoot ? .left : .right
        if motion.endsWithCatch {
            release = 0.75
            let bounce = motion == .bounceCatch
            let impactY = bounce ? CoachPose.ballRadius : Self.kickingFoot(side, delta: 0, x: side.sign * 0.145).ballContact.y
            let first = release + sqrt(2 * (1.10 - impactY) / Self.gravity)
            var events = [Contact(time: first, side: side, kind: bounce ? .floor : .foot)]
            if motion == .twoTouchCatch || motion == .alternatingCatch {
                events.append(Contact(time: first + 0.64, side: motion == .alternatingCatch ? .left : side))
            }
            contacts = events
            catchHeight = bounce ? 0.83 : 1.02
            // A floor rebound loses energy; the hands meet it below the release height.
            let flight: Float
            if bounce {
                let rebound = sqrt(2 * Self.gravity * (1.10 - impactY)) * 0.90
                flight = (rebound + sqrt(rebound * rebound - 2 * Self.gravity * (catchHeight - impactY))) / Self.gravity
            } else { flight = 0.66 }
            catchTime = events.last!.time + flight
            duration = catchTime! + 1.20
        } else {
            release = 0
            catchTime = nil
            catchHeight = 1.02
            let normal: Float = 0.70
            if motion == .moving {
                contacts = [Contact(time: 0, side: .right), Contact(time: normal, side: .left, offset: 0.16),
                            Contact(time: normal * 2, side: .right, offset: 0.16), Contact(time: normal * 3, side: .left)]
                duration = normal * 4
            } else if motion == .thigh {
                contacts = [Contact(time: 0, side: .right), Contact(time: 0.67, side: .right, kind: .thigh)]
                duration = 1.34
            } else {
                let first: Float = motion == .changeHeight ? 0.88 : (motion == .lowTouches ? 0.48 : normal)
                let second: Float = motion == .lowTouches ? 0.48 : normal
                contacts = [Contact(time: 0, side: side), Contact(time: first, side: motion == .otherFoot ? side : .left)]
                duration = first + second
            }
        }
    }

    func sample(seconds raw: Float) -> CoachPose {
        let t = raw - floor(raw / duration) * duration
        var pose = body(at: t)
        let points = contacts.map { contactPosition($0) }
        let hold = SIMD3<Float>(motion == .bounceCatch ? 0 : contacts[0].side.sign * 0.145, 1.10, points[0].z)
        var reach: Float = 0
        pose.held = 0
        pose.grip = 0
        if let catchTime {
            let catchPoint = SIMD3<Float>(points.last!.x, catchHeight, points.last!.z)
            if t < release {
                pose.ball = hold
                reach = 1
                pose.held = 1
                pose.grip = 1 - Self.ease((t - release + 0.06) / 0.12)
                pose.phase = "Get balanced"
            } else if t < contacts[0].time {
                let elapsed = t - release
                pose.ball = hold + SIMD3(0, -0.5 * Self.gravity * elapsed * elapsed, 0)
                reach = 1 - Self.ease((t - release) / 0.20)
                pose.grip = 1 - Self.ease((t - release + 0.06) / 0.12)
                pose.phase = "Let it drop"
            } else if t < catchTime {
                let index = contacts.lastIndex { $0.time <= t }!
                let nextTime = index + 1 < contacts.count ? contacts[index + 1].time : catchTime
                let nextPoint = index + 1 < contacts.count ? points[index + 1] : catchPoint
                pose.ball = Self.flight(from: points[index], to: nextPoint, elapsed: t - contacts[index].time,
                                        duration: nextTime - contacts[index].time)
                reach = Self.ease((t - catchTime + 0.22) / 0.22)
                pose.grip = Self.ease((t - catchTime + 0.035) / 0.07)
                pose.phase = motion == .bounceCatch ? "Let it bounce" : (contacts.count > 1 && index == 0 ? "First touch" : "A small lift")
            } else {
                let elapsed = t - catchTime
                let lastFlight = catchTime - contacts.last!.time
                let arrivalVelocity = (catchHeight - points.last!.y) / lastFlight - 0.5 * Self.gravity * lastFlight
                let absorb: Float = 0.12
                let give = min(0.095, max(0.055, -arrivalVelocity * absorb / 2.6))
                if elapsed < absorb {
                    pose.ball = catchPoint
                    pose.ball.y = Self.hermite(catchHeight, catchHeight - give, arrivalVelocity, 0, elapsed / absorb, absorb)
                } else {
                    let reset = Self.ease((elapsed - absorb) / 0.55)
                    pose.ball = simd_mix(catchPoint - SIMD3(0, give, 0), hold, SIMD3(repeating: reset))
                }
                pose.held = 1
                pose.grip = 1
                reach = 1
                pose.phase = elapsed < 0.2 ? "Soften the catch" : "Catch & reset"
            }
            pose.spin = 2 * .pi * min(1, max(0, (t - release) / (catchTime - release)))
            // Hands wait at the catch point before arrival, then travel with the held ball.
            let handCentre = t < release ? hold : (t < contacts[0].time ? hold : (t < catchTime ? catchPoint : pose.ball))
            positionHands(&pose, centre: handCentre, reach: reach)
        } else {
            let index = contacts.lastIndex { $0.time <= t }!
            let nextIndex = (index + 1) % contacts.count
            let nextTime = nextIndex == 0 ? duration : contacts[nextIndex].time
            pose.ball = Self.flight(from: points[index], to: points[nextIndex], elapsed: t - contacts[index].time,
                                    duration: nextTime - contacts[index].time)
            pose.spin = 2 * .pi * t / duration
            pose.phase = motion == .moving ? "Step, then settle" : (motion == .thigh ? (index == 0 ? "Lift toward your thigh" : "Back to your foot") : "Small, steady touches")
            positionHands(&pose, centre: pose.ball, reach: 0)
        }
        // Follow the ball without snapping the head at release/catch boundaries.
        pose.headPitch = 0.10 + 0.28 * Self.ease((1.28 - pose.ball.y) / 1.1)
        pose.headYaw = (pose.ball.x - pose.pelvis.x) * 0.28
        return pose
    }

    func contactPosition(_ contact: Contact) -> SIMD3<Float> {
        if contact.kind == .floor { return SIMD3(0, CoachPose.ballRadius, 0.34) }
        let pose = body(at: contact.time)
        if contact.kind == .thigh {
            return pose.hip(contact.side) * 0.35 + pose.knee(contact.side) * 0.65 + SIMD3(0, 0.17, 0.015)
        }
        return pose.foot(contact.side).ballContact
    }

    private func body(at t: Float) -> CoachPose {
        var pose = CoachPose()
        let events = motion.endsWithCatch ? contacts : (-1...1).flatMap { cycle in
            contacts.map { Contact(time: $0.time + Float(cycle) * duration, side: $0.side, offset: $0.offset, kind: $0.kind) }
        }
        var support: Float = 0
        var compression: Float = 0
        for event in events where event.kind != .floor {
            let delta = t - event.time
            let weight = Self.ease((delta + 0.34) / 0.22) * (1 - Self.ease((delta - 0.07) / 0.30))
            support -= event.side.sign * weight
            compression += weight * (event.kind == .thigh ? 0.055 : 0.022)
        }
        for side in CoachSide.allCases {
            let steps = events.filter { $0.side == side && $0.kind != .floor }.sorted { $0.time < $1.time }
            let next = steps.first { $0.time >= t - 0.29 }
            let previous = steps.last { $0.time < (next?.time ?? t) }
            var foot = CoachFoot(position: SIMD3(side.sign * 0.145 + (previous?.offset ?? 0), 0.095, 0))
            if let event = next {
                let delta = t - event.time
                let startX = side.sign * 0.145 + (previous?.offset ?? event.offset)
                let endX = side.sign * 0.145 + event.offset
                let x = startX + (endX - startX) * Self.ease((delta + 0.23) / 0.23)
                if event.kind == .thigh {
                    let lift = Self.ease((delta + 0.34) / 0.34) * (1 - Self.ease(delta / 0.29))
                    foot.position = SIMD3(x, 0.095 + 0.46 * lift, 0.25 * lift)
                    foot.pitch = 0.06 * lift
                } else { foot = Self.kickingFoot(side, delta: delta, x: x) }
            }
            if side == .left { pose.leftFoot = foot } else { pose.rightFoot = foot }
        }
        let centre = (pose.leftFoot.position.x + pose.rightFoot.position.x) * 0.5
        let soften = catchTime.map { Self.ease((t - $0 + 0.10) / 0.16) * (1 - Self.ease((t - $0 - 0.06) / 0.35)) } ?? 0
        let bounceBend: Float = motion == .bounceCatch ? 0.10 * Self.ease((t - catchTime! + 0.30) / 0.25) * (1 - Self.ease((t - catchTime! - 0.20) / 0.50)) : 0
        pose.pelvis = SIMD3(centre + support * 0.075, 0.96 - compression - soften * 0.028 - bounceBend, -0.025)
        pose.roll = -support * 0.035
        pose.lean = 0.055 + compression * 1.5 + soften * 0.06 + bounceBend * 0.6
        pose.twist = support * 0.06
        return pose
    }

    private func positionHands(_ pose: inout CoachPose, centre: SIMD3<Float>, reach: Float) {
        for side in CoachSide.allCases {
            let ready = SIMD3<Float>(pose.pelvis.x + side.sign * 0.28, 0.97 + (pose.pelvis.y - 0.96) * 0.5,
                                     0.20 + side.sign * pose.twist * 0.3)
            let target = centre + SIMD3<Float>(side.sign * 0.145, 0.055, 0)
            let hand = simd_mix(ready, target, SIMD3(repeating: reach))
            if side == .left { pose.leftHand = hand } else { pose.rightHand = hand }
        }
    }

    private static func kickingFoot(_ side: CoachSide, delta: Float, x: Float) -> CoachFoot {
        let height = curve(delta, keys: [(-0.23, 0, 0), (-0.10, 0.020, 0.25), (0, 0.075, 0.78), (0.09, 0.128, 0), (0.29, 0, 0)])
        let forward = curve(delta, keys: [(-0.23, 0, 0), (0, 0.16, 0.6), (0.09, 0.205, 0), (0.29, 0, 0)])
        let pitch = curve(delta, keys: [(-0.23, 0, 0), (0, -0.18, -0.4), (0.09, -0.23, 0), (0.29, 0, 0)])
        return CoachFoot(position: SIMD3(x, 0.095 + max(0, height), forward), pitch: pitch)
    }

    static func flight(from start: SIMD3<Float>, to end: SIMD3<Float>, elapsed: Float, duration: Float) -> SIMD3<Float> {
        let u = min(1, max(0, elapsed / duration))
        return simd_mix(start, end, SIMD3(repeating: u)) + SIMD3(0, 0.5 * gravity * duration * duration * u * (1 - u), 0)
    }
    static func ease(_ value: Float) -> Float {
        let u = min(1, max(0, value))
        return u * u * (3 - 2 * u)
    }
    private static func hermite(_ a: Float, _ b: Float, _ va: Float, _ vb: Float, _ u: Float, _ dt: Float) -> Float {
        (2 * u * u * u - 3 * u * u + 1) * a + (u * u * u - 2 * u * u + u) * va * dt +
        (-2 * u * u * u + 3 * u * u) * b + (u * u * u - u * u) * vb * dt
    }
    private static func curve(_ t: Float, keys: [(Float, Float, Float)]) -> Float {
        guard t > keys[0].0 else { return keys[0].1 }
        for i in 1..<keys.count where t <= keys[i].0 {
            let a = keys[i - 1], b = keys[i]
            return hermite(a.1, b.1, a.2, b.2, (t - a.0) / (b.0 - a.0), b.0 - a.0)
        }
        return keys.last!.1
    }
}
