import Foundation

/// Short observed impact shapes that a 100 ms ankle-motion comparison can miss.
/// These proofs inspect existing views only; the counter retains all later vetoes.
nonisolated enum MeasuredFootImpactRules {
    typealias Sample = GroundContactEvidence.Sample
    private static func valid(_ s: Sample) -> Bool {
        [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
            && s.width > 0 && s.height > 0 && (0.5...1).contains(s.confidence)
            && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
            && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
    }
    private static func valid(_ p: PoseLandmark, minimum: Double) -> Bool {
        [p.x,p.y,p.confidence].allSatisfy(\.isFinite)
            && (0...1).contains(p.x) && (0...1).contains(p.y)
            && (minimum...1).contains(p.confidence)
    }
    private static func stableSize(_ samples: [Sample], ratio: Double) -> Bool {
        !samples.isEmpty && samples.map(\.width).max()! <= ratio*samples.map(\.width).min()!
            && samples.map(\.height).max()! <= ratio*samples.map(\.height).min()!
    }
    private static func continuous(_ samples: [Sample]) -> Bool {
        Set(samples.map(\.timestampMs)).count == samples.count
            && zip(samples,samples.dropFirst()).allSatisfy { (1...70).contains($1.timestampMs-$0.timestampMs) }
    }

    /// The ball meets the toe at ankle height, the ankle flicks upward in the
    /// next exposure while the ball is still at impact, then the ball separates
    /// in two real views. A planted opposite foot anchors the entire window.
    /// This only supplements an independently confirmed foot contact.
    static func briefToeLift(_ ground: GroundContactEvidence) -> Bool {
        let views = (ground.compactFootSamples ?? ground.samples)
            .filter { (-101...134).contains($0.timestampMs-ground.contactMs) }
            .sorted { $0.timestampMs < $1.timestampMs }
        guard (6...10).contains(views.count), continuous(views), views.allSatisfy(valid),
              views.allSatisfy({ $0.confidence >= 0.7 }), stableSize(views,ratio:1.35),
              let contact = views.first(where: { $0.timestampMs == ground.contactMs }) else { return false }
        let before = views.filter { $0.timestampMs < ground.contactMs }
        let release = views.filter { (65...134).contains($0.timestampMs-ground.contactMs) }
        guard before.count >= 2, release.count >= 2,
              contact.ballY-before.first!.ballY >= 0.35*contact.height,
              release.allSatisfy({ contact.ballY-$0.ballY >= 0.2*contact.height }) else { return false }
        for side in BodySide.allCases {
            guard views.allSatisfy({ s in
                guard let foot=s.ankles[side], let hip=s.hips[side], let support=s.ankles[side.opposite] else { return false }
                return valid(foot,minimum:0.3) && valid(hip,minimum:0.5)
                    && valid(support,minimum:0.5) && foot.y > hip.y
            }), let foot=contact.ankles[side], foot.confidence >= 0.5,
                  hypot((contact.ballX-foot.x)/contact.width,(contact.ballY-foot.y)/contact.height) <= 0.3,
                  contact.ballY-foot.y <= 0.1*contact.height else { continue }
            let support=views.map { $0.ankles[side.opposite]! }
            guard support.map(\.x).max()!-support.map(\.x).min()! <= 0.15*contact.width,
                  support.map(\.y).max()!-support.map(\.y).min()! <= 0.15*contact.height else { continue }
            if views.contains(where: { s in
                guard (25...50).contains(s.timestampMs-contact.timestampMs),
                      let lifted=s.ankles[side], lifted.confidence >= 0.5 else { return false }
                return foot.y-lifted.y >= max(0.003,0.12*contact.height)
                    && (foot.y-contact.hips[side]!.y)-(lifted.y-s.hips[side]!.y) >= 0.12*contact.height
                    && abs(s.ballY-contact.ballY) <= 0.05*contact.height
            }) { return true }
        }
        return false
    }

    /// A shallow ball dip may still meet a visibly lifting toe. Require the
    /// ankle-height impact, continued upward toe motion, two clear ball-release
    /// views and a stable opposite foot; proximity alone supplies no evidence.
    static func shallowToeRebound(_ ground: GroundContactEvidence) -> Bool {
        shallowToeRebound(ground, at: ground.contactMs, allowsSettlingApproach: false)
    }

    /// Smoothing can propose the preceding exposure. The immediately next
    /// measured view may establish the same toe lift, with its own approach
    /// and release. The ball must continue into the impact without jumping.
    static func adjacentShallowToeRebound(_ ground: GroundContactEvidence) -> Int? {
        let ordered = (ground.compactFootSamples ?? ground.samples)
            .sorted { $0.timestampMs < $1.timestampMs }
        guard Set(ordered.map(\.timestampMs)).count == ordered.count,
              let index = ordered.firstIndex(where: { $0.timestampMs == ground.contactMs }),
              index+1 < ordered.count else { return nil }
        let proposal = ordered[index], contact = ordered[index+1]
        guard valid(proposal), valid(contact),
              (25...50).contains(contact.timestampMs-proposal.timestampMs),
              contact.ballY >= proposal.ballY,
              contact.ballY-proposal.ballY <= 0.35*contact.height,
              abs(contact.ballX-proposal.ballX) <= 0.35*contact.width,
              shallowToeRebound(ground, at: contact.timestampMs, allowsSettlingApproach: true)
        else { return nil }
        return contact.timestampMs
    }

    private static func shallowToeRebound(_ ground: GroundContactEvidence, at contactMs: Int,
                                          allowsSettlingApproach: Bool) -> Bool {
        let views = (ground.compactFootSamples ?? ground.samples)
            .filter { (-134...134).contains($0.timestampMs-contactMs) }
            .sorted { $0.timestampMs < $1.timestampMs }
        guard (7...10).contains(views.count), continuous(views), views.allSatisfy(valid),
              views.allSatisfy({ $0.confidence >= 0.7 }), stableSize(views,ratio:1.25),
              let contact = views.first(where: { $0.timestampMs == contactMs }) else { return false }
        let before = views.filter { (65...134).contains(contactMs-$0.timestampMs) }
        let release = views.filter { (65...134).contains($0.timestampMs-contactMs) }
        let approachConfirmed = allowsSettlingApproach
            ? before.allSatisfy({ $0.ballY <= contact.ballY })
                && before.filter({ contact.ballY-$0.ballY >= 0.1*contact.height }).count >= 2
            : before.allSatisfy({ contact.ballY-$0.ballY >= 0.1*contact.height })
        guard before.count >= 2, release.count >= 2,
              approachConfirmed,
              before.contains(where: { contact.ballY-$0.ballY >= max(0.007,0.15*contact.height) }),
              release.allSatisfy({ contact.ballY-$0.ballY >= 0.35*contact.height }),
              contact.ballY-release.last!.ballY >= 0.6*contact.height else { return false }
        for side in BodySide.allCases {
            guard views.allSatisfy({ s in
                guard let foot=s.ankles[side], let hip=s.hips[side], let support=s.ankles[side.opposite] else { return false }
                return valid(foot,minimum:0.3) && valid(hip,minimum:0.5)
                    && valid(support,minimum:0.7) && foot.y > hip.y
            }), let foot=contact.ankles[side], foot.confidence >= 0.5,
                  hypot((contact.ballX-foot.x)/contact.width,(contact.ballY-foot.y)/contact.height) <= 0.3,
                  contact.ballY-foot.y <= 0.05*contact.height else { continue }
            let support=views.map { $0.ankles[side.opposite]! }
            guard support.map(\.x).max()!-support.map(\.x).min()! <= 0.1*contact.width,
                  support.map(\.y).max()!-support.map(\.y).min()! <= 0.1*contact.height,
                  before.contains(where: { s in
                      let ankle=s.ankles[side]!
                      return ankle.confidence >= 0.5 && ankle.y-foot.y >= 0.1*contact.height
                          && ((contact.ballY-foot.y)-(s.ballY-ankle.y)) >= 0.25*contact.height
                          && hypot((ankle.x-foot.x)/contact.width,(ankle.y-foot.y)/contact.height) >= 0.2
                  }) else { continue }
            if views.contains(where: { s in
                let lifted=s.ankles[side]!
                return (25...50).contains(s.timestampMs-contact.timestampMs) && lifted.confidence >= 0.5
                    && foot.y-lifted.y >= max(0.003,0.1*contact.height)
                    && (foot.y-contact.hips[side]!.y)-(lifted.y-s.hips[side]!.y) >= 0.1*contact.height
                    && s.ballY < contact.ballY && s.ballY-lifted.y <= 0.05*contact.height
            }) { return true }
        }
        return false
    }

    /// A nearby moving foot cannot rescue a rebound distinctly below both
    /// ankles. Require two agreeing low views, a descending nearest ankle and
    /// stable support height. Horizontal stepping alone supplies no kick proof.
    static func descendingFloorRebound(_ ground: GroundContactEvidence) -> Int? {
        descendingFloorRebound(ground, recentFloor: nil)
    }

    /// An independently proven, recent bounce can locate the turf when a body
    /// box sits too low. A new contact still needs its own measured rebound,
    /// descending nearest ankle, stable support, and clearance below that ankle.
    static func reboundNearRecentFloor(_ ground: GroundContactEvidence,
                                       previous: GroundContactEvidence) -> Int? {
        guard (1...650).contains(ground.contactMs-previous.contactMs) else { return nil }
        return descendingFloorRebound(ground, recentFloor: previous)
    }

    static func resolvedFloorTime(_ ground: GroundContactEvidence) -> Int? {
        ground.unliftedFloorReboundMs ?? ground.corroboratedFloorReboundMs
            ?? descendingFloorRebound(ground)
    }

    private static func matchesRecentFloor(_ previous: GroundContactEvidence,
                                          impact: Sample, near: [Sample], nearest: BodySide) -> Bool {
        guard let time = resolvedFloorTime(previous), (150...600).contains(impact.timestampMs-time),
              let old = previous.samples.first(where: { $0.timestampMs == time }), valid(old),
              old.confidence >= 0.7, near.allSatisfy({ $0.confidence >= 0.7 }),
              stableSize([old,impact],ratio:1.25),
              abs(old.imageAspect-impact.imageAspect) < 0.001,
              abs(old.ballX-impact.ballX) <= 1.5*impact.width,
              impact.ballY-impact.ankles[nearest]!.y >= 0.25*impact.height else { return false }
        let support = nearest.opposite
        let oldViews = previous.samples.filter { abs($0.timestampMs-time) <= 101 }
        guard oldViews.count >= 6, oldViews.allSatisfy({ s in
            guard let a=s.ankles[support] else { return false };return valid(a,minimum:0.5)
        }) else { return false }
        let oldFeet=oldViews.map { $0.ankles[support]! }, feet=near.map { $0.ankles[support]! }
        func middle(_ xs: [Double]) -> Double { xs.sorted()[xs.count/2] }
        func stable(_ feet: [PoseLandmark]) -> Bool {
            feet.map(\.x).max()!-feet.map(\.x).min()! <= 0.15*impact.width
                && feet.map(\.y).max()!-feet.map(\.y).min()! <= 0.15*impact.height
        }
        let oldY=middle(oldFeet.map(\.y)), newY=middle(feet.map(\.y))
        // Exposure timing and ball localization can move a single lower edge.
        // Bound the old floor by two adjacent measured low views, rather than
        // treating the deepest pixel in one image as a permanent floor line.
        let floorViews=oldViews.filter { s in
            abs(s.timestampMs-time) <= 34 && valid(s) && s.confidence >= 0.7
                && BodySide.allCases.allSatisfy { side in
                    s.ankles[side].map { valid($0,minimum:0.5) } == true
                }
                && s.ballY >= BodySide.allCases.map { s.ankles[$0]!.y }.max()!+0.1*s.height
        }
        guard floorViews.count >= 2, stableSize(floorViews,ratio:1.25) else { return false }
        let floorEdges=floorViews.map { $0.ballY+$0.height/2-oldY }
        let lower=floorEdges.min()!, upper=floorEdges.max()!
        let currentEdge=impact.ballY+impact.height/2-newY
        guard stable(oldFeet), stable(feet),
              abs(middle(oldFeet.map(\.x))-middle(feet.map(\.x))) <= 0.25*impact.width,
              abs(oldY-newY) <= 0.25*impact.height,
              upper-lower <= 0.35*impact.height,
              (lower-0.2*impact.height...upper+0.2*impact.height).contains(currentEdge)
        else { return false }
        return true
    }

    private static func descendingFloorRebound(_ ground: GroundContactEvidence,
                                               recentFloor: GroundContactEvidence?) -> Int? {
        guard !ground.confirmsCompactFootContact else { return nil }
        let ordered=ground.samples.sorted { $0.timestampMs < $1.timestampMs }
        guard Set(ordered.map(\.timestampMs)).count == ordered.count else { return nil }
        for impact in ordered where (0...50).contains(ground.contactMs-impact.timestampMs) {
            let near=ordered.filter { abs($0.timestampMs-impact.timestampMs) <= 101 }
            guard (6...9).contains(near.count), continuous(near), near.allSatisfy(valid), stableSize(near,ratio:1.25),
                  near.allSatisfy({ s in BodySide.allCases.allSatisfy { side in
                      guard let ankle=s.ankles[side], let hip=s.hips[side] else { return false }
                      return valid(ankle,minimum:0.5) && valid(hip,minimum:0.5) && ankle.y > hip.y
                  } }) else { continue }
            let before=near.filter { $0.timestampMs < impact.timestampMs }
            let after=near.filter { $0.timestampMs > impact.timestampMs }
            guard before.count >= 2, after.count >= 2,
                  impact.timestampMs-before.first!.timestampMs >= 65,
                  after.last!.timestampMs-impact.timestampMs >= 65,
                  impact.ballY-before.first!.ballY >= 0.35*impact.height,
                  impact.ballY-after.last!.ballY >= 0.2*impact.height,
                  near.allSatisfy({ $0.ballY <= impact.ballY+0.05*impact.height }) else { continue }
            func distance(_ side: BodySide) -> Double {
                let ankle=impact.ankles[side]!
                return hypot((impact.ballX-ankle.x)/impact.width,(impact.ballY-ankle.y)/impact.height)
            }
            let nearest=BodySide.allCases.min { distance($0) < distance($1) }!
            let deep = impact.ballY-BodySide.allCases.map({ impact.ankles[$0]!.y }).max()! >= 0.4*impact.height
                && near.filter({ s in abs(s.timestampMs-impact.timestampMs) <= 34
                    && s.ballY-BodySide.allCases.map({ s.ankles[$0]!.y }).max()! >= 0.3*impact.height
                }).count >= 2
            let nearMeasuredFloor = recentFloor.map { previous in
                impact.ballY >= BodySide.allCases.map({ impact.ankles[$0]!.y }).max()!-0.05*impact.height
                    && near.filter({ s in abs(s.timestampMs-impact.timestampMs) <= 34
                        && s.ballY >= BodySide.allCases.map({ s.ankles[$0]!.y }).max()!-0.05*impact.height
                    }).count >= 2
                    && matchesRecentFloor(previous,impact:impact,near:near,nearest:nearest)
            } == true
            guard recentFloor == nil ? deep : nearMeasuredFloor else { continue }
            guard before.suffix(2).allSatisfy({ impact.ankles[nearest]!.y-$0.ankles[nearest]!.y >= 0.1*impact.height }) else { continue }
            let supportY=near.map { $0.ankles[nearest.opposite]!.y }
            guard supportY.max()!-supportY.min()! <= 0.15*impact.height else { continue }
            return impact.timestampMs
        }
        return nil
    }
}
