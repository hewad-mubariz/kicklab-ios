import Foundation

/// Temporary experiment. Pose proximity is an eligibility filter, not proof of
/// physical contact; the trajectory, ground and hand checks still apply.
nonisolated enum RestrictedTouchPolicy {
    enum Region: String { case head, knee, foot }
    enum Failure: String, Codable, Sendable {
        case missingBall, missingPose, invalidGeometry, torsoOverlap, outsideAllowedRegions
        case insufficientContactViews, handsUncertain, handsNearBall
        case lowContactNeedsFootEvidence
    }
    struct Assessment {
        var region: Region? = nil
        var failure: Failure? = nil
    }
    typealias Point = PosePoint

    static func region(ball: Point, width: Double, height: Double,
                       joints: [BodyJoint: Point], imageAspect: Double) -> Region? {
        assess(ball: ball, width: width, height: height, joints: joints, imageAspect: imageAspect).region
    }

    static func assess(ball: Point, width: Double, height: Double,
                       joints: [BodyJoint: Point], imageAspect: Double) -> Assessment {
        guard [ball.x, ball.y, width, height, imageAspect].allSatisfy(\.isFinite),
              (0...1).contains(ball.x), (0...1).contains(ball.y),
              width > 0, height > 0, width <= 1, height <= 1, imageAspect > 0,
              joints.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return .init(failure: .invalidGeometry)
        }
        // A low foot has toes extending away from the shin in either image
        // direction. Its eligibility depends on visible lower-leg geometry,
        // not on whether shoulders/hands higher in the image were detected.
        // Keep raised feet/torso overlap on the separate motion-evidence path.
        if let lh = joints[.leftHip], let rh = joints[.rightHip],
           let lk = joints[.leftKnee], let rk = joints[.rightKnee] {
            let lowestKnee = max(lk.y, rk.y)
            let lowestHip = max(lh.y, rh.y)
            let radius = max(width*imageAspect, height)/2
            for side in BodySide.allCases {
                guard let knee = joints[side.knee], let ankle = joints[side.ankle] else { continue }
                let shin = hypot((knee.x-ankle.x)*imageAspect, knee.y-ankle.y)
                guard shin > 0.03, shin < 0.5, radius <= 0.8*shin,
                      ball.y >= lowestKnee + 0.25*shin, ball.y-radius > lowestHip,
                      ball.y+radius >= ankle.y-0.1*shin,
                      ball.y <= ankle.y+radius*0.5,
                      ankle.y >= lowestKnee else { continue }
                if hypot((ball.x-ankle.x)*imageAspect, ball.y-ankle.y) <= radius + 0.45*shin {
                    return .init(region: .foot)
                }
            }
        }
        guard let ls = joints[.leftShoulder], let rs = joints[.rightShoulder],
              let lh = joints[.leftHip], let rh = joints[.rightHip] else {
            return .init(failure: .missingPose)
        }
        // Compare both axes in frame-height units, including landscape video.
        func scaled(_ p: Point) -> Point { .init(x: p.x * imageAspect, y: p.y) }
        func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x-b.x, a.y-b.y) }
        func midpoint(_ a: Point, _ b: Point) -> Point { .init(x: (a.x+b.x)/2, y: (a.y+b.y)/2) }
        func extend(_ a: Point, _ b: Point, by t: Double) -> Point {
            .init(x: b.x+(b.x-a.x)*t, y: b.y+(b.y-a.y)*t)
        }
        func segmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
            let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
            let t = length > 0 ? max(0, min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
            return distance(p, .init(x: a.x+t*dx, y: a.y+t*dy))
        }
        let p = scaled(ball), torso = [ls, rs, rh, lh].map(scaled)
        let shoulders = midpoint(torso[0], torso[1]), hips = midpoint(torso[3], torso[2])
        let torsoLength = distance(shoulders, hips), shoulderWidth = distance(torso[0], torso[1])
        let radius = max(width * imageAspect, height) / 2
        guard torsoLength > 0.02, shoulderWidth > 0.01, radius <= torsoLength * 0.5 else {
            return .init(failure: .invalidGeometry)
        }

        // Reject the entire torso, including a hand hidden behind the ball.
        // Raised-knee/foot overlap requires separate evidence across nearby frames.
        var inside = false
        for i in torso.indices {
            let a = torso[i], b = torso[(i+1) % torso.count]
            if segmentDistance(p, a, b) <= radius { return .init(failure: .torsoOverlap) }
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x {
                inside.toggle()
            }
        }
        guard !inside else { return .init(failure: .torsoOverlap) }

        if let nose = joints[.nose].map(scaled) {
            let center = extend(shoulders, nose, by: 0.25)
            let headRadius = max(shoulderWidth * 0.45, distance(shoulders, nose) * 0.35)
            if distance(p, center) <= radius + headRadius { return .init(region: .head) }
        }
        for side in BodySide.allCases {
            if let hip = joints[side.hip].map(scaled), let knee = joints[side.knee].map(scaled) {
                if distance(p, knee) <= radius + distance(hip, knee) * 0.18 { return .init(region: .knee) }
            }
            if let knee = joints[side.knee].map(scaled), let ankle = joints[side.ankle].map(scaled) {
                let foot = extend(knee, ankle, by: 0.45)
                if segmentDistance(p, ankle, foot) <= radius + distance(knee, ankle) * 0.15 { return .init(region: .foot) }
            }
        }
        return .init(failure: .outsideAllowedRegions)
    }
}
