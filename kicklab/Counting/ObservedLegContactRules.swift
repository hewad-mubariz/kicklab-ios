import Foundation

/// Positive leg evidence when arm landmarks are unavailable. A toe tap can
/// move mostly sideways, so upward ankle travel alone is not a kick test.
/// This supplies body eligibility only; ground, hand and handling vetoes remain.
nonisolated enum ObservedLegContactRules {
    private enum Contact { case foot, knee }
    typealias Sample = FootPoseSample
    typealias Point = PosePoint

    static func contactTime(_ input: [Sample], at timestampMs: Int, usesTemporalEvidence: Bool = false,
                            usesCadenceWindow: Bool = false, allowsNearSupportFoot: Bool = false) -> Int? {
        // Preserve an already established physical impact time. A recovery
        // must not move the downstream hand check away from that contact.
        if usesTemporalEvidence, !usesCadenceWindow,
           let original = contactTime(input,at:timestampMs) { return original }
        // A weak context detection must not discard a different, fully observed
        // approach/contact/release trio. Keep the proposed impact itself and
        // retain the same elapsed-time, size and positive motion requirements.
        let samples = input.filter { !allowsNearSupportFoot || $0.pose.timestampMs == timestampMs || $0.pose.confidence >= 0.5 }
            .sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        let timeWindow = usesCadenceWindow ? -201...201 : -100...150
        guard (3...(usesCadenceWindow ? 9 : 7)).contains(samples.count),
              Set(samples.map { $0.pose.timestampMs }).count == samples.count,
              samples.contains(where: { $0.pose.timestampMs == timestampMs }),
              samples.allSatisfy({ sample in
                  let p = sample.pose
                  return timeWindow.contains(p.timestampMs-timestampMs)
                    && [p.ball.x,p.ball.y,p.width,p.height,p.confidence,p.imageAspect].allSatisfy(\.isFinite)
                    && (0...1).contains(p.ball.x) && (0...1).contains(p.ball.y)
                    && p.width > 0 && p.width <= 1 && p.height > 0 && p.height <= 1
                    && (usesTemporalEvidence || p.confidence >= 0.5) && p.imageAspect > 0
              }), !usesTemporalEvidence || TemporalContactEvidence.supportsBallTrack(samples.map(\.pose)) else { return nil }

        // The smoothed candidate can precede physical contact. Use only real
        // buffered observations within 100 ms; never invent a hidden joint.
        for contact in samples where (0...(usesCadenceWindow ? 101 : 100)).contains(contact.pose.timestampMs-timestampMs) {
            let p = ball(contact), diameter = max(contact.pose.width*contact.pose.imageAspect, contact.pose.height)
            let radius = diameter/2
            for side in BodySide.allCases {
                let other = side.opposite
                guard let hip = point(contact, side.hip), let knee = point(contact, side.knee),
                      let foot = point(contact, side.ankle),
                      let support = point(contact, other.ankle, confidence: 0.5),
                      let supportKnee = point(contact, other.knee) else { continue }
                let shin = distance(knee,foot), supportShin = distance(supportKnee,support)
                // A raised shin foreshortens in the image. Its supporting shin
                // supplies scale without fabricating the hidden foot position.
                let footScale = usesCadenceWindow ? max(shin, supportShin) : shin
                guard (0.04...0.45).contains(shin), (0.04...0.45).contains(supportShin),
                      radius <= 0.8*footScale else { continue }
                for kind in [Contact.foot, .knee] {
                    let joint = kind == .foot ? foot : knee
                    let name = kind == .foot ? side.ankle : side.knee
                    let near = distance(p,joint)
                    switch kind {
                    case .foot:
                        // Use the same toe reach as the ordinary low-foot
                        // region, in either direction from the ankle. Both the
                        // lifted ankle and the ball must clear the support foot.
                        guard p.y+radius >= hip.y, p.y <= foot.y+0.25*radius,
                              near <= radius+0.45*footScale,
                              foot.y <= support.y-0.2*diameter,
                              p.y+radius <= support.y-(allowsNearSupportFoot ? 0.2 : 0.4)*diameter else { continue }
                    case .knee:
                        guard supportKnee.y-knee.y >= 0.5*supportShin,
                              support.y-foot.y >= 0.5*supportShin,
                              foot.y-knee.y >= 0.25*supportShin,
                              p.y <= knee.y+0.25*radius,
                              near <= radius+0.25*supportShin else { continue }
                    }
                    for before in samples where (50...(usesCadenceWindow ? 201 : 130)).contains(contact.pose.timestampMs-before.pose.timestampMs) {
                        for after in samples where (33...(usesCadenceWindow ? 151 : 130)).contains(after.pose.timestampMs-contact.pose.timestampMs)
                            && after.pose.timestampMs-before.pose.timestampMs <= (usesCadenceWindow ? 301 : 230) {
                            let views = [before,contact,after]
                            let stableSize = usesTemporalEvidence ? TemporalContactEvidence.stableSize(views.map(\.pose))
                                : views.map({ $0.pose.width }).max()! <= 1.35*views.map({ $0.pose.width }).min()!
                                    && views.map({ $0.pose.height }).max()! <= 1.35*views.map({ $0.pose.height }).min()!
                            guard stableSize,
                                  let aHip = point(before,side.hip), let cHip = point(after,side.hip),
                                  let aJoint = point(before,name), let cJoint = point(after,name),
                                  views.filter({ point($0,name,confidence: 0.5) != nil }).count >= 2,
                                  max(distance(aHip,hip),distance(cHip,hip)) <= 0.35*diameter,
                                  stableSupport(views, side: other, diameter: diameter)
                                    || (usesTemporalEvidence && TemporalContactEvidence.stableSupport(views,side:other,diameter:diameter)) else { continue }
                            let a = relative(aJoint,to: aHip), b = relative(joint,to: hip), c = relative(cJoint,to: cHip)
                            // Require observed movement before impact and a
                            // changed position afterward. A stationary foot,
                            // whole-body translation or one-frame pose spike
                            // cannot recover a ball bounce.
                            guard distance(a,b) >= 0.2*diameter,
                                  distance(a,c) >= 0.1*diameter else { continue }
                            if kind == .knee, a.y-b.y < 0.15*diameter { continue }
                            let aBall = ball(before), cBall = ball(after)
                            guard (p.y-hip.y)-(aBall.y-aHip.y) >= 0.12*diameter,
                                  (p.y-hip.y)-(cBall.y-cHip.y) >= 0.12*diameter,
                                  distance(aBall,aJoint)-near >= 0.25*diameter,
                                  distance(cBall,cJoint)-near >= 0.12*diameter else { continue }
                            return contact.pose.timestampMs
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func stableSupport(_ views: [Sample], side: BodySide, diameter: Double) -> Bool {
        var positions: [Point] = []
        for view in views {
            guard let ankle = point(view,side.ankle,confidence: 0.5),
                  let left = point(view,.leftHip), let right = point(view,.rightHip) else { return false }
            // The pelvis center is a translation reference. A turn can shift
            // one projected hip while the supporting foot stays planted.
            positions.append(relative(ankle,to: .init(x: (left.x+right.x)/2, y: (left.y+right.y)/2)))
        }
        return positions.allSatisfy { a in positions.allSatisfy { distance(a,$0) <= 0.2*diameter } }
    }

    private static func point(_ sample: Sample, _ name: BodyJoint, confidence: Double = 0.3) -> Point? {
        guard let p = sample.landmarks[name], [p.x,p.y,p.confidence].allSatisfy(\.isFinite),
              (0...1).contains(p.x), (0...1).contains(p.y),
              (confidence...1).contains(p.confidence) else { return nil }
        return .init(x: p.x*sample.pose.imageAspect, y: p.y)
    }
    private static func ball(_ sample: Sample) -> Point {
        .init(x: sample.pose.ball.x*sample.pose.imageAspect, y: sample.pose.ball.y)
    }
    private static func relative(_ p: Point, to anchor: Point) -> Point { .init(x: p.x-anchor.x, y: p.y-anchor.y) }
    private static func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x-b.x,a.y-b.y) }
}
