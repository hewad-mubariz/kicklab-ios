import Foundation

/// The score counts football contacts (feet, legs, torso and head). Hands/arms
/// and ground bounces add nothing. This helper supplies a conservative hand veto;
/// it does not claim to label every remaining touch's body part.
nonisolated enum JugglingContactRules {
    typealias Point = PosePoint

    static func canResolveTorsoOverlap(ball: Point, height: Double, joints: [BodyJoint: Point]) -> Bool {
        guard height.isFinite, height > 0,
              let leftHip = joints[.leftHip], let rightHip = joints[.rightHip],
              let nose = joints[.nose] else { return false }
        return ball.y > nose.y && ball.y + height / 2 < min(leftHip.y, rightHip.y)
    }

    /// Require multiple confident distal finger joints, belonging to the same
    /// visible hand and associated with this person's wrist. A nearby arm alone
    /// cannot override the original protection for legal body contacts.
    static func fingersTouchBall(ball: Point, width: Double, height: Double,
                                 bodyWrists: [Point], landmarks: [HandLandmark]) -> Bool {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              let wrist = landmarks.first(where: { $0.finger == 0 && $0.confidence >= 0.25 }),
              bodyWrists.contains(where: { hypot($0.x-wrist.x, $0.y-wrist.y) <= 0.06 }) else { return false }
        let touching = landmarks.filter {
            (1...5).contains($0.finger) && $0.confidence >= 0.35 &&
            hypot(($0.x-ball.x)/(width/2), ($0.y-ball.y)/(height/2)) <= 1.3
        }
        return touching.count >= 3 && Set(touching.map(\.finger)).count >= 2
    }

    /// Segment attribution follows the lab's pose.py, including its protection
    /// against a wrist near a legitimate leg touch. Inputs share normalized
    /// upright video coordinates. Only sufficiently confident joints belong here.
    static func isHand(ball: Point, width: Double, joints: [BodyJoint: Point],
                       measuredArms: [BodyJoint: PoseLandmark]? = nil) -> Bool {
        // A weak arm estimate can jump onto a ball above a raised knee. When
        // raw confidence is supplied, require measured arm endpoints for the
        // arm veto. Keep all legal-body geometry and the caller's separate
        // finger/holding checks available.
        func measured(_ names: BodyJoint...) -> Bool {
            guard let measuredArms else { return true }
            return names.allSatisfy { name in
                guard let p = measuredArms[name] else { return false }
                return [p.x,p.y,p.confidence].allSatisfy(\.isFinite)
                    && (0...1).contains(p.x) && (0...1).contains(p.y)
                    && (0.5...1).contains(p.confidence)
            }
        }
        func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x - b.x, a.y - b.y) }
        func middle(_ a: Point, _ b: Point) -> Point {
            Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        func extend(_ a: Point, _ b: Point, by factor: Double) -> Point {
            Point(x: b.x + (b.x - a.x) * factor, y: b.y + (b.y - a.y) * factor)
        }
        func segment(_ a: Point, _ b: Point) -> (Double, Double) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((ball.x - a.x) * dx + (ball.y - a.y) * dy) / length)) : 0
            return (distance(ball, Point(x: a.x + t * dx, y: a.y + t * dy)), t)
        }
        // A midpoint alone confuses arms hanging beside a torso with a grip.
        if width > 0, measured(.leftWrist, .rightWrist),
           let left = joints[.leftWrist], let right = joints[.rightWrist],
           distance(ball, middle(left, right)) <= 0.07, distance(left, right) <= 1.5 * width {
            return true
        }
        var hand = Double.infinity, legal = Double.infinity
        for side in BodySide.allCases {
            if let hip = joints[side.hip], let knee = joints[side.knee] {
                legal = min(legal, segment(hip, knee).0)
            }
            if let knee = joints[side.knee], let ankle = joints[side.ankle] {
                legal = min(legal, segment(knee, extend(knee, ankle, by: 0.6)).0)
            }
            if let shoulder = joints[side.shoulder], let elbow = joints[side.elbow] {
                let (d, along) = segment(shoulder, elbow)
                if along < 0.3 { legal = min(legal, d) }
                else if measured(side.shoulder, side.elbow) { hand = min(hand, d) }
            }
            if measured(side.elbow, side.wrist), let elbow = joints[side.elbow], let wrist = joints[side.wrist] {
                hand = min(hand, segment(elbow, wrist).0)
            }
        }
        if let ls = joints[.leftShoulder], let rs = joints[.rightShoulder],
           let lh = joints[.leftHip], let rh = joints[.rightHip] {
            let shoulders = middle(ls, rs)
            legal = min(legal, segment(shoulders, middle(lh, rh)).0)
            if let nose = joints[.nose] {
                legal = min(legal, segment(nose, extend(shoulders, nose, by: 0.5)).0)
            }
        }
        return hand <= 0.07 && legal - hand >= 0.03
    }
}
