import Foundation

/// The score counts football contacts (feet, legs, torso and head). Hands/arms
/// and ground bounces add nothing. This helper supplies a conservative hand veto;
/// it does not claim to label every remaining touch's body part.
nonisolated enum JugglingContactRules {
    struct Point {
        var x, y: Double
    }

    /// Segment attribution follows the lab's pose.py, including its protection
    /// against a wrist near a legitimate leg touch. Inputs share normalized
    /// upright video coordinates. Only sufficiently confident joints belong here.
    static func isHand(ball: Point, width: Double, joints: [String: Point]) -> Bool {
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
        if width > 0, let left = joints["left_wrist"], let right = joints["right_wrist"],
           distance(ball, middle(left, right)) <= 0.07, distance(left, right) <= 1.5 * width {
            return true
        }
        var hand = Double.infinity, legal = Double.infinity
        for side in ["left", "right"] {
            if let hip = joints[side + "_hip"], let knee = joints[side + "_knee"] {
                legal = min(legal, segment(hip, knee).0)
            }
            if let knee = joints[side + "_knee"], let ankle = joints[side + "_ankle"] {
                legal = min(legal, segment(knee, extend(knee, ankle, by: 0.6)).0)
            }
            if let shoulder = joints[side + "_shoulder"], let elbow = joints[side + "_elbow"] {
                let (d, along) = segment(shoulder, elbow)
                if along < 0.3 { legal = min(legal, d) } else { hand = min(hand, d) }
            }
            if let elbow = joints[side + "_elbow"], let wrist = joints[side + "_wrist"] {
                hand = min(hand, segment(elbow, wrist).0)
            }
        }
        if let ls = joints["left_shoulder"], let rs = joints["right_shoulder"],
           let lh = joints["left_hip"], let rh = joints["right_hip"] {
            let shoulders = middle(ls, rs)
            legal = min(legal, segment(shoulders, middle(lh, rh)).0)
            if let nose = joints["nose"] {
                legal = min(legal, segment(nose, extend(shoulders, nose, by: 0.5)).0)
            }
        }
        return hand <= 0.07 && legal - hand >= 0.03
    }
}
