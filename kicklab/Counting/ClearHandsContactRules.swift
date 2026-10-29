import Foundation

/// Body eligibility for the touch-debug experiment, after the counter's
/// trajectory, player-region and ground gates. A 2D torso overlap cannot tell
/// chest from raised foot; positive hand clearance can resolve either case.
nonisolated enum ClearHandsContactRules {
    typealias Sample = ContactPoseSample
    typealias Point = PosePoint

    static func failure(_ input: [Sample], at timestampMs: Int) -> RestrictedTouchPolicy.Failure? {
        let samples = input.sorted { $0.timestampMs < $1.timestampMs }
        guard let contact = samples.first(where: { $0.timestampMs == timestampMs }),
              let before = samples.last(where: { $0.timestampMs < timestampMs }),
              let after = samples.first(where: { $0.timestampMs > timestampMs }),
              timestampMs-before.timestampMs <= 100, after.timestampMs-timestampMs <= 100,
              after.timestampMs-before.timestampMs <= 150 else { return .insufficientContactViews }
        // Use consecutive observations bracketing the proposed contact. A
        // hidden hand at impact cannot be replaced by a clearer, later pose.
        let views = [before, contact, after]
        for s in views {
            guard [s.ball.x, s.ball.y, s.width, s.height, s.confidence, s.imageAspect].allSatisfy(\.isFinite),
                  (0...1).contains(s.ball.x), (0...1).contains(s.ball.y),
                  s.width > 0, s.width <= 1, s.height > 0, s.height <= 1,
                  s.confidence >= 0.5, s.imageAspect > 0 else { return .invalidGeometry }
        }
        guard views.map(\.width).max()! <= 1.35*views.map(\.width).min()!,
              views.map(\.height).max()! <= 1.35*views.map(\.height).min()! else { return .invalidGeometry }
        // The body-box floor gate can miss a bounce beside the player's feet.
        // Hand clearance is not kick evidence at/below the lowest visible
        // ankle. Leave those candidates to the existing foot-contact checks.
        let ankles = [.leftAnkle, .rightAnkle].compactMap { contact.joints[$0] }
            .filter { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
        if let lowest = ankles.map(\.y).max(), contact.ball.y >= lowest {
            return .lowContactNeedsFootEvidence
        }
        for s in views {
            if let failure = handFailure(in: s) { return failure }
        }
        return nil
    }

    /// Exact arm-clearance checks, also used when independently measured
    /// impact and first-release images locate the physical contact.
    static func handFailure(in s: Sample) -> RestrictedTouchPolicy.Failure? {
        guard [s.ball.x,s.ball.y,s.width,s.height,s.confidence,s.imageAspect].allSatisfy(\.isFinite),
              (0...1).contains(s.ball.x), (0...1).contains(s.ball.y),
              s.width > 0, s.width <= 1, s.height > 0, s.height <= 1,
              s.confidence >= 0.5, s.imageAspect > 0 else { return .invalidGeometry }
        func point(_ name: BodyJoint) -> Point? {
            guard let p = s.joints[name], p.x.isFinite, p.y.isFinite,
                  (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
            return .init(x: p.x*s.imageAspect, y: p.y)
        }
        func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x-b.x, a.y-b.y) }
        func segmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
            let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
            let t = length > 0 ? max(0, min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
            return distance(p, .init(x: a.x+t*dx, y: a.y+t*dy))
        }
        let ball = Point(x: s.ball.x*s.imageAspect, y: s.ball.y)
        let radius = max(s.width*s.imageAspect, s.height)/2
        // Player proximity was checked by the counter. Hidden hips or
        // ankles do not make otherwise visible arms uncertain.
        guard let ls = point(.leftShoulder), let rs = point(.rightShoulder),
              distance(ls, rs) > 0.01 else {
            return .missingPose
        }
        for side in BodySide.allCases {
            guard let wrist = point(side.wrist), let elbow = point(side.elbow),
                  let shoulder = point(side.shoulder) else { return .handsUncertain }
            // Wrists are not fingertips. Leave room for the hand beyond
            // the wrist, scaled by the visible forearm and ball radius.
            let handReach = max(0.8*radius, 0.4*distance(elbow, wrist))
            guard distance(ball, wrist) > radius+handReach,
                  segmentDistance(ball, elbow, wrist) > radius else { return .handsNearBall }
            // The shoulder itself is legal; an upper arm crossing the
            // ball is not positive evidence of a clear chest contact.
            let upperArm = Point(x: shoulder.x+0.3*(elbow.x-shoulder.x),
                                 y: shoulder.y+0.3*(elbow.y-shoulder.y))
            guard segmentDistance(ball, upperArm, elbow) > radius else { return .handsNearBall }
        }
        return nil
    }
}
