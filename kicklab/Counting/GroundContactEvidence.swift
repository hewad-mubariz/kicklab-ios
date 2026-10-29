import Foundation

/// Nearby observations for checking planted feet independently of the ball's
/// motion-blurred box size. Only candidate contacts request these poses.
nonisolated struct GroundContactEvidence: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        let timestampMs: Int
        let ballX, ballY, width, height, confidence, imageAspect: Double
        let ankles, hips: [BodySide: PoseLandmark]
    }
    let contactMs: Int
    let samples: [Sample]
    var checksBallBelowFeet: Bool? = nil
    /// Absent in historical evidence: preserve its original replay verdict.
    var requiresLowBallCenter: Bool? = nil
    /// Perspective and blur during the approach may change box size. Only the
    /// observed impact/release window may establish the tighter size bound.
    var usesLocalImpactSize: Bool? = nil
    /// Old archives omit this. A reversal with a gap in the original impact
    /// observations needs positive foot evidence if it is at ankle height.
    var requiresPositiveLowContact: Bool? = nil
    /// A weak raised foot beside a floor-height ball requires positive contact
    /// evidence even when the trajectory itself has no missing frames.
    var requiresResolvedLowFoot: Bool? = nil
    /// One dropped 30 Hz exposure in the approach (at most 134 ms between
    /// confident views) must not hide an otherwise complete below-feet proof.
    var toleratesApproachGap: Bool? = nil
    /// The caller checks the floor line; this only establishes a planted
    /// stance with the ball clearly beside it. Old traces omit the flag.
    var checksBallBesideFeet: Bool? = nil
    /// The planted-feet proof tolerates the same single dropped approach
    /// exposure as the below-feet proof. Old traces omit it.
    var toleratesPlantedApproachGap: Bool? = nil
    /// With the floor positively confirmed, a kick may only override it when
    /// an ankle near the ball actually travelled; pose jitter cannot.
    var requiresMovingAnkleForRescue: Bool? = nil
    /// A detection hole of up to 200 ms in the approach does not break the
    /// below-feet proof when both feet stayed planted across the whole window:
    /// nothing could have kicked a ball that ends up under two unmoved ankles.
    var allowsStationaryHole: Bool? = nil
    /// A one-exposure floor touch at 30 fps: the lower ball edge at least half
    /// a ball height under both planted ankles, between them, after a clear
    /// drop, with a rebound. One view suffices when nothing else moved.
    var checksDeepFloorContact: Bool? = nil
    /// A close toe contact can rotate the shoe without large ankle travel.
    /// Missing in old traces preserves their original ground verdict.
    var checksCompactFootContact: Bool? = nil
    /// A resolved compact kick already supplies positive contact evidence.
    /// Older traces keep requiring the separate broad ankle-motion proof.
    var usesCompactFootEligibility: Bool? = nil
    /// The first release exposure may still be near the vertical minimum while
    /// the foot is already separating. It must not descend; every later view
    /// must show the existing upward departure. Nil keeps the original proof.
    var allowsSettlingCompactRelease: Bool? = nil
    /// A smoothed reversal can be one 30 Hz exposure away from impact. Only
    /// the immediately adjacent, fully visible observation within 50 ms may
    /// supply the same compact-contact proof. Nil preserves old trace results.
    var checksAdjacentCompactImpact: Bool? = nil
    /// Actual later exposures for the compact proof only. Floor proofs retain
    /// their original sample window and cannot disappear when it is extended.
    var compactFootSamples: [Sample]? = nil
    /// A measured weak ankle can be corroborated by confident observations on
    /// both sides. Its coordinates and confidence are never replaced.
    var corroboratesCompactAnkles: Bool? = nil
    /// A real first release may still travel with the rising toe. Require
    /// separation in the later view, with at most one missing 30 FPS image.
    var usesMeasuredCompactRelease: Bool? = nil
    /// A compact contact below the kicking ankle needs that ankle visibly
    /// raised above a stable opposite foot on both sides of impact.
    var checksRaisedCompactFoot: Bool? = nil
    /// Separate from the height proof so earlier debug traces remain exact.
    var usesCorroboratedRaisedToe: Bool? = nil

    /// A planted stance cannot prove a floor bounce when its confidence
    /// filter removed the impact. Nil preserves historical trace decisions.
    var requiresPlantedImpactEvidence: Bool? = nil

    /// Opt-in proof for a low rebound under unlifted feet. Missing in saved
    /// traces preserves their original decisions.
    var checksUnliftedFloorRebound: Bool? = nil
    /// Versioned separately so saved historical verdicts replay exactly.
    var checksCorroboratedFloorRebound: Bool? = nil

    /// A moving foot beside the ball is not necessarily its source of lift.
    /// Require a measured drop/release below both ankles, a stable support
    /// foot, and no pre-impact ankle lift. A compact toe proof takes priority.
    /// Examine the adjacent actual minimum as smoothing can shift the proposal.
    var unliftedFloorReboundMs: Int? {
        guard checksUnliftedFloorRebound == true, !confirmsCompactFootContact else { return nil }
        let ordered = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard Set(ordered.map(\.timestampMs)).count == ordered.count else { return nil }
        // Only look back from a smoothed proposal. A later low exposure must
        // not overwrite an already resolved earlier toe contact.
        for impact in ordered where (0...50).contains(contactMs-impact.timestampMs) {
            let near = ordered.filter { abs($0.timestampMs-impact.timestampMs) <= 101 }
            guard (6...9).contains(near.count),
                  near.allSatisfy({ s in
                      [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                        && (0.5...1).contains(s.confidence)
                        && s.width > 0 && s.height > 0
                        && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                        && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
                        && BodySide.allCases.allSatisfy { side in
                            guard let ankle = s.ankles[side], let hip = s.hips[side] else { return false }
                            return [ankle,hip].allSatisfy {
                                [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                                    && (0...1).contains($0.x) && (0...1).contains($0.y)
                                    && (0.5...1).contains($0.confidence)
                            } && ankle.y > hip.y
                        }
                  }),
                  zip(near,near.dropFirst()).allSatisfy({ $1.timestampMs-$0.timestampMs <= 70 }),
                  near.map(\.height).max()! <= 1.25*near.map(\.height).min()!,
                  near.map(\.width).max()! <= 1.25*near.map(\.width).min()! else { continue }
            let before = near.filter { $0.timestampMs < impact.timestampMs }
            let after = near.filter { $0.timestampMs > impact.timestampMs }
            let height = impact.height
            guard before.count >= 2, after.count >= 2,
                  impact.timestampMs-before.first!.timestampMs >= 65,
                  after.last!.timestampMs-impact.timestampMs >= 65,
                  impact.ballY-before.first!.ballY >= 0.35*height,
                  impact.ballY-after.last!.ballY >= 0.2*height,
                  // A tiny allowance covers localization jitter at the minimum.
                  near.allSatisfy({ $0.ballY <= impact.ballY+0.05*height }),
                  impact.ballY >= BodySide.allCases.map({ impact.ankles[$0]!.y }).max()!+0.1*height,
                  near.filter({ s in
                      abs(s.timestampMs-impact.timestampMs) <= 34
                          && s.ballY >= BodySide.allCases.map({ s.ankles[$0]!.y }).max()!-0.05*height
                  }).count >= 2 else { continue }
            // Do not veto a foot already lifting before the rebound, even if
            // the ball overlaps the coarse ankle/floor geometry.
            guard BodySide.allCases.allSatisfy({ side in
                before.allSatisfy { $0.ankles[side]!.y-impact.ankles[side]!.y <= 0.08*height }
            }) else { continue }
            let nearest = BodySide.allCases.min { a,b in
                func distance(_ side: BodySide) -> Double {
                    let ankle = impact.ankles[side]!
                    return hypot((impact.ballX-ankle.x)/impact.width,(impact.ballY-ankle.y)/height)
                }
                return distance(a) < distance(b)
            }!
            let support: BodySide = nearest == .left ? .right : .left
            // Keep ankle-height toe contacts eligible. This proof requires
            // the ball center distinctly below even the nearer ankle.
            guard impact.ballY-impact.ankles[nearest]!.y >= 0.25*height else { continue }
            let xs = near.map { $0.ankles[support]!.x/impact.width }
            let ys = near.map { $0.ankles[support]!.y/height }
            guard xs.max()!-xs.min()! <= 0.15, ys.max()!-ys.min()! <= 0.15 else { continue }
            return impact.timestampMs
        }
        return nil
    }

    /// A deep rebound can survive a brief ankle-confidence dip only when
    /// two confident neighboring views corroborate the measured coordinates.
    /// The actual minimum must have confident ankles, no preceding lift, a
    /// stable support foot, and two views distinctly below both ankles.
    var corroboratedFloorReboundMs: Int? {
        guard checksCorroboratedFloorRebound == true else { return nil }
        guard !confirmsCompactFootContact else { return nil }
        let all=samples.sorted { $0.timestampMs < $1.timestampMs }
        guard Set(all.map(\.timestampMs)).count == all.count else { return nil }
        func valid(_ p: PoseLandmark, _ confidence: Double) -> Bool {
            [p.x,p.y,p.confidence].allSatisfy(\.isFinite) && (0...1).contains(p.x)
                && (0...1).contains(p.y) && (confidence...1).contains(p.confidence)
        }
        func ankle(_ sample: Sample, _ side: BodySide) -> Bool {
            guard let value=sample.ankles[side],valid(value,0.4) else { return false }
            if value.confidence >= 0.5 { return true }
            guard let before=all.last(where: { $0.timestampMs < sample.timestampMs && ($0.ankles[side]?.confidence ?? 0) >= 0.5 }),
                  let after=all.first(where: { $0.timestampMs > sample.timestampMs && ($0.ankles[side]?.confidence ?? 0) >= 0.5 }),
                  sample.timestampMs-before.timestampMs <= 67, after.timestampMs-sample.timestampMs <= 67,
                  after.timestampMs-before.timestampMs <= 101,
                  let b=before.ankles[side],let c=after.ankles[side],valid(b,0.5),valid(c,0.5) else {return false}
            let fraction=Double(sample.timestampMs-before.timestampMs)/Double(after.timestampMs-before.timestampMs)
            let x=b.x+(c.x-b.x)*fraction,y=b.y+(c.y-b.y)*fraction
            return hypot((value.x-x)/sample.width,(value.y-y)/sample.height) <= 0.1
        }
        for impact in all where (0...50).contains(contactMs-impact.timestampMs) {
            let near=all.filter { (-101...67).contains($0.timestampMs-impact.timestampMs) }
            guard (6...7).contains(near.count),
                zip(near,near.dropFirst()).allSatisfy({ (1...50).contains($1.timestampMs-$0.timestampMs) }),
                near.allSatisfy({ s in
                    [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                        && s.width > 0 && s.height > 0 && (0.7...1).contains(s.confidence)
                        && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                        && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
                        && BodySide.allCases.allSatisfy { side in
                            guard let a=s.ankles[side],let hip=s.hips[side] else{return false}
                            return ankle(s,side) && valid(hip,0.5) && a.y > hip.y
                        }
                }),near.map(\.height).max()! <= 1.25*near.map(\.height).min()!,
                near.map(\.width).max()! <= 1.25*near.map(\.width).min()!,
                BodySide.allCases.allSatisfy({ (impact.ankles[$0]?.confidence ?? 0) >= 0.5 }) else{continue}
            let before=near.filter { $0.timestampMs < impact.timestampMs },after=near.filter { $0.timestampMs > impact.timestampMs }
            guard before.count >= 3,after.count >= 2,
                impact.timestampMs-before.first!.timestampMs >= 95,
                after.last!.timestampMs-impact.timestampMs >= 65,
                impact.ballY-before.first!.ballY >= 0.35*impact.height,
                impact.ballY-after.last!.ballY >= 0.2*impact.height,
                near.allSatisfy({ $0.ballY <= impact.ballY+0.05*impact.height }),
                impact.ballY-BodySide.allCases.map({impact.ankles[$0]!.y}).max()! >= 0.4*impact.height,
                near.filter({ s in abs(s.timestampMs-impact.timestampMs) <= 34 &&
                    s.ballY-BodySide.allCases.map({s.ankles[$0]!.y}).max()! >= 0.3*s.height }).count >= 2,
                BodySide.allCases.allSatisfy({ side in before.allSatisfy { $0.ankles[side]!.y-impact.ankles[side]!.y <= 0.08*impact.height } }) else {continue}
            let nearest=BodySide.allCases.min { a,b in
                func d(_ side: BodySide)->Double { let f=impact.ankles[side]!;return hypot((impact.ballX-f.x)/impact.width,(impact.ballY-f.y)/impact.height) }
                return d(a)<d(b)
            }!
            let support=near.map { $0.ankles[nearest.opposite]! }
            guard support.map(\.confidence).min()! >= 0.5,
                support.map(\.x).max()!-support.map(\.x).min()! <= 0.15*impact.width,
                support.map(\.y).max()!-support.map(\.y).min()! <= 0.15*impact.height else {continue}
            return impact.timestampMs
        }
        return nil
    }

    /// Detect sparse impact tracks for the existing extra foot-proof route.
    /// Rechecked images must be excluded: they can establish floor evidence
    /// but do not erase the original gap. Pose uncertainty is checked separately.
    static func hasImpactTrackingGap(contactMs: Int, originalTimestampsMs: [Int],
                                     missingBallTimestampsMs: [Int], approachMs: Int = 67) -> Bool {
        // Sparse capture cadence is not a tracking failure. Require at least
        // two actual analyzed exposures without a ball near the impact. The
        // approach side may look further back than the release side: a hole in
        // the last 134 ms before impact removes the floor proof's approach views.
        guard Set(missingBallTimestampsMs.filter { (-approachMs...67).contains($0-contactMs) }).count >= 2 else { return false }
        let span = max(100, approachMs+33)
        let times = [contactMs-span] + Set(originalTimestampsMs.filter {
            (-span...100).contains($0-contactMs)
        }).sorted() + [contactMs+100]
        // More than two 30 Hz intervals, allowing timestamp rounding. Restrict
        // the gap to the impact neighborhood, not an unrelated approach gap.
        return zip(times, times.dropFirst()).contains {
            $1-$0 > 70 && $0 < contactMs+67 && $1 > contactMs-approachMs
        }
    }

    var needsPositiveFootContact: Bool {
        let uncertainPlantedImpact = hasUncertainPlantedImpact
        let weakLowFoot = requiresResolvedLowFoot == true && hasWeakFootBesideLowBall
        guard requiresPositiveLowContact == true || uncertainPlantedImpact || weakLowFoot else { return false }
        if usesCompactFootEligibility == true, checksCompactFootContact == true,
           confirmsCompactFootContact { return false }
        // Removing an unsupported floor verdict is not permission to count.
        // This route still requires measured foot evidence.
        if uncertainPlantedImpact || weakLowFoot { return true }
        return samples.contains { s in
            guard abs(s.timestampMs-contactMs) <= 67,
                  [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite),
                  (0...1).contains(s.ballX), (0...1).contains(s.ballY),
                  s.width > 0, s.width <= 1, s.height > 0, s.height <= 1, s.confidence >= 0.5,
                  let left = s.ankles[.left], let right = s.ankles[.right],
                  [left,right].allSatisfy({
                      [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.confidence >= 0.5
                  }) else { return false }
            // Match the existing low-center floor criterion. A toe flick
            // reversing clearly above the ankles keeps its previous route.
            return s.ballY >= max(left.y,right.y)-0.25*s.height
        }
    }

    /// Uncertainty, not a floor verdict: the whole ball is below a weak nearby
    /// ankle, while its lower edge reaches a separate, sustained support foot.
    /// A resolved foot/leg contact can still establish a legal touch. Missing
    /// support, camera/stance movement, clipped balls and ordinary ankle overlap
    /// cannot trigger this extra evidence request.
    var hasWeakFootBesideLowBall: Bool {
        let all = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard Set(all.map(\.timestampMs)).count == all.count else { return false }
        func valid(_ p: PoseLandmark, minimum: Double) -> Bool {
            [p.x,p.y,p.confidence].allSatisfy(\.isFinite) && (0...1).contains(p.x)
                && (0...1).contains(p.y) && (minimum...1).contains(p.confidence)
        }
        for s in all where abs(s.timestampMs-contactMs) <= 67 {
            guard [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite),
                  s.width > 0, s.height > 0, (0.7...1).contains(s.confidence),
                  s.ballX-s.width/2 >= 0, s.ballX+s.width/2 <= 1,
                  s.ballY-s.height/2 >= 0, s.ballY+s.height/2 <= 1 else { continue }
            for side in BodySide.allCases {
                guard let uncertain = s.ankles[side], valid(uncertain, minimum: 0.3), uncertain.confidence < 0.5,
                      let support = s.ankles[side.opposite], valid(support, minimum: 0.6),
                      s.ballY-s.height/2 > uncertain.y,
                      hypot((s.ballX-uncertain.x)/s.width,(s.ballY-uncertain.y)/s.height) <= 0.9,
                      s.ballY+s.height/2 >= support.y-0.1*s.height else { continue }
                let supported = all.filter { view in
                    guard abs(view.timestampMs-s.timestampMs) <= 134,
                          let p = view.ankles[side.opposite] else { return false }
                    return valid(p, minimum: 0.6)
                }
                guard supported.contains(where: { (40...134).contains(s.timestampMs-$0.timestampMs) }),
                      supported.contains(where: { (40...134).contains($0.timestampMs-s.timestampMs) }) else { continue }
                let feet = supported.map { $0.ankles[side.opposite]! }
                if feet.map(\.x).max()!-feet.map(\.x).min()! <= 0.1*s.width,
                   feet.map(\.y).max()!-feet.map(\.y).min()! <= 0.1*s.height { return true }
            }
        }
        return false
    }

    /// Perspective can place a turf rebound slightly above the ankle line.
    /// This is uncertainty requiring kick evidence, not proof of a floor hit.
    /// Only interrupted impacts with a fully visible ball and two confident,
    /// distant ankles qualify; nearby toe contacts keep their existing route.
    var hasDistantLowBall: Bool {
        guard requiresPositiveLowContact == true else { return false }
        return samples.contains { s in
            guard abs(s.timestampMs-contactMs) <= 67,
                  [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite),
                  s.width > 0, s.height > 0, (0.7...1).contains(s.confidence),
                  s.ballX-s.width/2 >= 0, s.ballX+s.width/2 <= 1,
                  s.ballY-s.height/2 >= 0, s.ballY+s.height/2 <= 1,
                  let left=s.ankles[.left], let right=s.ankles[.right],
                  [left,right].allSatisfy({ a in
                      [a.x,a.y,a.confidence].allSatisfy(\.isFinite)
                          && (0...1).contains(a.x) && (0...1).contains(a.y)
                          && (0.7...1).contains(a.confidence)
                  }), s.ballY >= max(left.y,right.y)-0.35*s.height else { return false }
            return [left,right].allSatisfy {
                hypot((s.ballX-$0.x)/s.width,(s.ballY-$0.y)/s.height) >= 1.1
            }
        }
    }

    static let signature = "|cadence-ground-v2"

    func confirmsGroundContact(corroboratingWeakAnkles: Bool, cadenceAware: Bool = false) -> Bool {
        if checksCompactFootContact == true && confirmsCompactFootContact { return false }
        return confirmsPlantedFeet(corroboratingWeakAnkles: corroboratingWeakAnkles)
            || (checksBallBelowFeet == true && confirmsBallBelowFeet)
            || (cadenceAware && confirmsSparsePlantedFeet)
            || (checksDeepFloorContact == true && confirmsDeepFloorContact)
    }

    /// Tight impact overlap, a measured pre-impact lift and an immediate ball
    /// departure. Proximity alone and a later rebound beside a still foot are
    /// insufficient. Uses the existing poses; no extra image work or latency.
    var confirmsCompactFootContact: Bool {
        compactFootContactMs != nil
    }

    var compactFootContactMs: Int? {
        if confirmsCompactFootContact(at: contactMs) { return contactMs }
        guard checksAdjacentCompactImpact == true else { return nil }
        let views = (compactFootSamples ?? samples).sorted { $0.timestampMs < $1.timestampMs }
        guard let index = views.firstIndex(where: { $0.timestampMs == contactMs }) else { return nil }
        func fullyVisible(_ s: Sample) -> Bool {
            s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
        }
        guard fullyVisible(views[index]) else { return nil }
        for neighbor in [index-1,index+1] where views.indices.contains(neighbor) {
            let candidate = views[neighbor]
            if abs(candidate.timestampMs-contactMs) <= 50, fullyVisible(candidate),
               confirmsCompactFootContact(at: candidate.timestampMs) { return candidate.timestampMs }
        }
        return nil
    }

    private func confirmsCompactFootContact(at contactMs: Int) -> Bool {
        let views = (compactFootSamples ?? samples).sorted { $0.timestampMs < $1.timestampMs }
        guard let contact = views.first(where: { $0.timestampMs == contactMs }),
              Set(views.map(\.timestampMs)).count == views.count,
              views.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                    && (0...1).contains(s.ballX) && (0...1).contains(s.ballY)
                    && (0...1).contains(s.confidence) && s.confidence >= 0.5
                    && s.width > 0 && s.width <= 1 && s.height > 0 && s.height <= 1
              }) else { return false }
        func ankle(_ s: Sample, _ side: BodySide) -> PoseLandmark? {
            guard let a = s.ankles[side], [a.x,a.y,a.confidence].allSatisfy(\.isFinite),
                  (0...1).contains(a.x), (0...1).contains(a.y), (0.3...1).contains(a.confidence) else { return nil }
            if a.confidence >= 0.5 { return a }
            guard corroboratesCompactAnkles == true,
                  let before = views.last(where: { $0.timestampMs < s.timestampMs && ($0.ankles[side]?.confidence ?? 0) >= 0.5 }),
                  let after = views.first(where: { $0.timestampMs > s.timestampMs && ($0.ankles[side]?.confidence ?? 0) >= 0.5 }),
                  s.timestampMs-before.timestampMs <= 134, after.timestampMs-s.timestampMs <= 134,
                  after.timestampMs-before.timestampMs <= 201,
                  let b = before.ankles[side], let c = after.ankles[side],
                  [b.x,b.y,c.x,c.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            let fraction = Double(s.timestampMs-before.timestampMs)/Double(after.timestampMs-before.timestampMs)
            let expectedX = b.x+(c.x-b.x)*fraction, expectedY = b.y+(c.y-b.y)*fraction
            guard hypot((a.x-expectedX)/s.width,(a.y-expectedY)/s.height) <= 0.2 else { return nil }
            return a
        }
        for side in BodySide.allCases {
            guard let foot = ankle(contact, side),
                  hypot((contact.ballX-foot.x)/contact.width, (contact.ballY-foot.y)/contact.height) <= 0.3,
                  contact.ballY-foot.y <= 0.2*contact.height
                    || (checksRaisedCompactFoot == true && raisedAboveSupport(contact: contact, side: side, views: views)) else { continue }
            let raised = checksRaisedCompactFoot == true && raisedAboveSupport(contact: contact, side: side, views: views)
            let before = views.filter { (25...250).contains(contactMs-$0.timestampMs) && ankle($0, side) != nil }
            let after = views.filter { (25...100).contains($0.timestampMs-contactMs) && ankle($0, side) != nil }
            guard before.count >= 2, after.count >= 2,
                  after.first!.timestampMs-contactMs <= (usesMeasuredCompactRelease == true ? 67 : 50),
                  after.enumerated().allSatisfy({ i, s in
                      let a = ankle(s, side)!
                      let minimumRise = allowsSettlingCompactRelease == true && i == 0 ? 0 : 0.12*contact.height
                      // At a verified raised toe the first release can still move
                      // with the shoe. Allow only 5% of a ball of localization
                      // error here; every subsequent view must fully separate.
                      let minimumSeparation = usesMeasuredCompactRelease == true && i == 0
                        ? (raised && usesCorroboratedRaisedToe == true ? -0.05*contact.height : 0) : 0.12*contact.height
                      return contact.ballY-s.ballY >= minimumRise
                        && (contact.ballY-foot.y)-(s.ballY-a.y) >= minimumSeparation
                  }),
                  before.contains(where: { (ankle($0, side)!.y-foot.y) >= max(0.003,0.08*contact.height) }),
                  before.contains(where: { (contact.ballY-foot.y)-($0.ballY-ankle($0, side)!.y) >= 0.35*contact.height }) else { continue }
            return true
        }
        return false
    }

    private func raisedAboveSupport(contact: Sample, side: BodySide, views: [Sample]) -> Bool {
        let opposite: BodySide = side == .left ? .right : .left
        let near = views.filter { abs($0.timestampMs-contact.timestampMs) <= 67 }
        guard near.contains(where: { $0.timestampMs < contact.timestampMs }),
              near.contains(where: { $0.timestampMs > contact.timestampMs }) else { return false }
        var support: [Double] = [], clearances: [Double] = []
        for sample in near {
            guard let foot = sample.ankles[side], let other = sample.ankles[opposite],
                  [foot,other].allSatisfy({ [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                    && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  foot.confidence >= 0.3, other.confidence >= 0.5,
                  other.y-foot.y >= (usesCorroboratedRaisedToe == true ? 0.2 : 0.25)*sample.height else { return false }
            support.append(other.y)
            clearances.append((other.y-foot.y)/sample.height)
        }
        if usesCorroboratedRaisedToe == true,
           clearances.sorted()[clearances.count/2] < 0.3 { return false }
        return support.max()!-support.min()! <= 0.1*contact.height
    }

    /// The ball's lower edge is at least half a ball height below the lower of
    /// two confident, planted ankles and between them, after at least two
    /// approach views above both ankles, with a rebound. The ankles must stay
    /// within 0.15 ball heights across every confident view within 67 ms.
    /// Outdoor toe taps can also reach this geometry with little ankle travel;
    /// the versioned compact-contact check in confirmsGroundContact handles
    /// that ambiguity before this heuristic supplies a floor verdict.
    var confirmsDeepFloorContact: Bool {
        guard checksDeepFloorContact == true else { return false }
        let views = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard (5...13).contains(views.count),
              Set(views.map(\.timestampMs)).count == views.count,
              let contact = views.first(where: { $0.timestampMs == contactMs }),
              views.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence,s.imageAspect].allSatisfy(\.isFinite)
                    && (0...1).contains(s.ballX) && (0...1).contains(s.ballY)
                    && s.width > 0 && s.width <= 1 && s.height > 0 && s.height <= 1
                    && s.imageAspect > 0 && abs(s.imageAspect-contact.imageAspect) < 0.001
                    && (-350...150).contains(s.timestampMs-contactMs)
              }) else { return false }
        let scale = median(views.map(\.height))
        let strong = views.filter { s in
            s.confidence >= 0.5 && BodySide.allCases.allSatisfy { side in
                guard let a = s.ankles[side], let h = s.hips[side] else { return false }
                return [a,h].allSatisfy {
                    [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.confidence >= 0.5
                } && a.y > h.y
            }
        }
        guard strong.count >= 5, strong.contains(where: { $0.timestampMs == contactMs }),
              strong.map(\.height).max()! <= 1.35*strong.map(\.height).min()! else { return false }
        let left = contact.ankles[.left]!, right = contact.ankles[.right]!
        guard contact.ballY+contact.height/2 >= max(left.y,right.y)+0.5*scale,
              contact.ballX >= min(left.x,right.x)-contact.width/2,
              contact.ballX <= max(left.x,right.x)+contact.width/2 else { return false }
        let near = strong.filter { abs($0.timestampMs-contactMs) <= 67 }
        guard near.count >= 2 else { return false }
        for side in BodySide.allCases {
            let xs = near.map { $0.ankles[side]!.x*contact.imageAspect/scale }, ys = near.map { $0.ankles[side]!.y/scale }
            guard xs.max()!-xs.min()! <= 0.15, ys.max()!-ys.min()! <= 0.15 else { return false }
        }
        let approach = strong.filter {
            $0.timestampMs <= contactMs-50 && $0.ballY+$0.height/2
                < min($0.ankles[.left]!.y,$0.ankles[.right]!.y)-0.1*scale
        }
        let departure = strong.contains {
            $0.timestampMs >= contactMs+25 && contact.ballY-$0.ballY >= 0.2*scale
        }
        return approach.count >= 2 && departure
    }

    /// A ball center crossing below BOTH confident ankles, then rising again,
    /// supplies floor evidence even when small pose drift prevents a planted-
    /// feet verdict. A visible kick can still rescue this in the caller.
    var confirmsBallBelowFeet: Bool {
        let views = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard (7...13).contains(views.count),
              Set(views.map(\.timestampMs)).count == views.count,
              let contact = views.first(where: { $0.timestampMs == contactMs }),
              views.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence,s.imageAspect].allSatisfy(\.isFinite)
                    && (0...1).contains(s.ballX) && (0...1).contains(s.ballY)
                    && s.width > 0 && s.width <= 1 && s.height > 0 && s.height <= 1
                    && s.imageAspect > 0 && abs(s.imageAspect-contact.imageAspect) < 0.001
                    && (-350...150).contains(s.timestampMs-contactMs)
              }) else { return false }
        let scale = median(views.map(\.height))
        let strong = views.filter { s in
            s.confidence >= 0.5 && BodySide.allCases.allSatisfy { side in
                guard let a = s.ankles[side], let h = s.hips[side] else { return false }
                return [a,h].allSatisfy {
                    [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.confidence >= 0.5
                } && a.y > h.y
            }
        }
        guard strong.count >= 7, strong.contains(where: { $0.timestampMs == contactMs }),
              strong.first!.timestampMs <= contactMs-200,
              strong.last!.timestampMs >= contactMs+25,
              zip(strong,strong.dropFirst()).allSatisfy({ $1.timestampMs-$0.timestampMs <= (toleratesApproachGap == true ? 134 : 110) })
                || (allowsStationaryHole == true
                    && zip(strong,strong.dropFirst()).filter({ $1.timestampMs-$0.timestampMs > 134 }).count == 1
                    && zip(strong,strong.dropFirst()).allSatisfy({ $1.timestampMs-$0.timestampMs <= 200 })
                    && stableFeet(raw: strong, smoothed: strong, aspect: contact.imageAspect, scale: scale)),
              strong.map(\.height).max()! <= (usesLocalImpactSize == true ? 1.6 : 1.35)*strong.map(\.height).min()!,
              strong.map(\.width).max()! <= (usesLocalImpactSize == true ? 1.6 : 1.35)*strong.map(\.width).min()! else { return false }
        if usesLocalImpactSize == true,
           strong.map(\.height).max()! > 1.35*strong.map(\.height).min()!
            || strong.map(\.width).max()! > 1.35*strong.map(\.width).min()! {
            let impact = strong.filter { (-100...100).contains($0.timestampMs-contactMs) }
            guard impact.count >= 4, impact.first!.timestampMs <= contactMs-50,
                  impact.last!.timestampMs >= contactMs+50,
                  impact.map(\.height).max()! <= 1.25*impact.map(\.height).min()!,
                  impact.map(\.width).max()! <= 1.25*impact.map(\.width).min()! else { return false }
        }
        let below = strong.filter { s in
            let left = s.ankles[.left]!, right = s.ankles[.right]!
            return abs(s.timestampMs-contactMs) <= 67 && s.ballY >= max(left.y,right.y)
                && s.ballX >= min(left.x,right.x)-s.width/2
                && s.ballX <= max(left.x,right.x)+s.width/2
        }
        let approach = strong.filter {
            $0.timestampMs <= contactMs-50 && $0.ballY+$0.height/2
                < min($0.ankles[.left]!.y,$0.ankles[.right]!.y)-0.1*scale
        }
        let departure = strong.contains {
            $0.timestampMs >= contactMs+25 && contact.ballY-$0.ballY >= 0.2*scale
        }
        return below.count >= 2 && approach.count >= 2 && departure
    }

    /// A ball that reaches the floor line with its center at the ankle line
    /// and clearly outside the stance bounced beside the feet. Low juggling
    /// keeps the ball near the ankles throughout, so a clear approach from
    /// above the ankles and a real rebound are both required. The caller
    /// supplies the floor-line test, and a resolved kick can still rescue.
    var confirmsBallBesideFeet: Bool {
        guard checksBallBesideFeet == true else { return false }
        let views = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard (7...13).contains(views.count),
              Set(views.map(\.timestampMs)).count == views.count,
              let contact = views.first(where: { $0.timestampMs == contactMs }),
              views.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence,s.imageAspect].allSatisfy(\.isFinite)
                    && (0...1).contains(s.ballX) && (0...1).contains(s.ballY)
                    && s.width > 0 && s.width <= 1 && s.height > 0 && s.height <= 1
                    && s.imageAspect > 0 && abs(s.imageAspect-contact.imageAspect) < 0.001
                    && (-350...150).contains(s.timestampMs-contactMs)
              }) else { return false }
        let scale = median(views.map(\.height))
        let strong = views.filter { s in
            s.confidence >= 0.5 && BodySide.allCases.allSatisfy { side in
                guard let a = s.ankles[side], let h = s.hips[side] else { return false }
                return [a,h].allSatisfy {
                    [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.confidence >= 0.5
                } && a.y > h.y
            }
        }
        // A ball at the image edge can lose width to clipping without moving
        // its lower edge, so only the height bounds the box size here.
        guard strong.count >= 7, strong.contains(where: { $0.timestampMs == contactMs }),
              strong.first!.timestampMs <= contactMs-200,
              strong.last!.timestampMs >= contactMs+25,
              zip(strong,strong.dropFirst()).allSatisfy({ $1.timestampMs-$0.timestampMs <= 134 }),
              strong.map(\.height).max()! <= 1.35*strong.map(\.height).min()! else { return false }
        func besideStance(_ s: Sample) -> Bool {
            let left = s.ankles[.left]!.x, right = s.ankles[.right]!.x
            return s.ballX <= min(left,right)-s.width/2 || s.ballX >= max(left,right)+s.width/2
        }
        let beside = strong.filter { abs($0.timestampMs-contactMs) <= 67 && besideStance($0) }
        guard beside.count >= 2, besideStance(contact),
              contact.ballY >= max(contact.ankles[.left]!.y,contact.ankles[.right]!.y)-0.25*scale else { return false }
        let approach = strong.filter {
            $0.timestampMs <= contactMs-50 && $0.ballY+$0.height/2
                < min($0.ankles[.left]!.y,$0.ankles[.right]!.y)-0.1*scale
        }
        let departure = strong.contains {
            $0.timestampMs >= contactMs+25 && contact.ballY-$0.ballY >= 0.2*scale
        }
        return approach.count >= 2 && departure
    }

    /// A clear approach toward two planted feet is positive floor evidence.
    /// Missing/occluded pose and unresolved small taps remain inconclusive.
    var confirmsPlantedFeet: Bool {
        confirmsPlantedFeet(corroboratingWeakAnkles: false)
    }

    var hasUncertainPlantedImpact: Bool {
        guard requiresPlantedImpactEvidence == true else { return false }
        return confirmsPlantedFeet(corroboratingWeakAnkles: true, requiresImpact: false)
            && !confirmsPlantedFeet(corroboratingWeakAnkles: true, requiresImpact: true)
    }

    func confirmsPlantedFeet(corroboratingWeakAnkles: Bool) -> Bool {
        confirmsPlantedFeet(corroboratingWeakAnkles: corroboratingWeakAnkles,
                            requiresImpact: requiresPlantedImpactEvidence == true)
    }

    private func confirmsPlantedFeet(corroboratingWeakAnkles: Bool, requiresImpact: Bool) -> Bool {
        let ordered = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard ordered.count <= 13, ordered.count >= 7,
              Set(ordered.map(\.timestampMs)).count == ordered.count,
              ordered.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence,s.imageAspect].allSatisfy(\.isFinite)
                    && s.width > 0 && s.height > 0 && s.width <= 1 && s.height <= 1 && s.imageAspect > 0
                    && (-350...150).contains(s.timestampMs-contactMs)
              }), let contact = ordered.first(where: { $0.timestampMs == contactMs }),
              contact.confidence >= 0.5 else { return false }
        let aspect = contact.imageAspect
        guard ordered.allSatisfy({ abs($0.imageAspect-aspect) < 0.001 }) else { return false }
        let scale = median(ordered.map(\.height))
        let strong = ordered.filter { s in
            s.confidence >= 0.5 && BodySide.allCases.allSatisfy { side in
                guard let ankle = s.ankles[side], let hip = s.hips[side] else { return false }
                return [ankle,hip].allSatisfy {
                    [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.confidence >= 0.5
                } && ankle.y > hip.y
            }
        }
        let strongTimes = Set(strong.map(\.timestampMs))
        var valid = strong
        if corroboratingWeakAnkles {
            // A partially hidden ankle may corroborate its two immediately
            // adjacent, confident observations. Keep its ACTUAL position: do
            // not interpolate a missing ankle or fill a missing camera frame.
            valid = ordered.enumerated().compactMap { index, s in
                if strongTimes.contains(s.timestampMs) { return s }
                guard index > 0, index < ordered.count-1, s.confidence >= 0.5 else { return nil }
                let before = ordered[index-1], after = ordered[index+1]
                guard strongTimes.contains(before.timestampMs), strongTimes.contains(after.timestampMs),
                      s.timestampMs-before.timestampMs <= 100, after.timestampMs-s.timestampMs <= 100,
                      after.timestampMs-before.timestampMs <= 150 else { return nil }
                let t = Double(s.timestampMs-before.timestampMs)/Double(after.timestampMs-before.timestampMs)
                for side in BodySide.allCases {
                    guard let ankle = s.ankles[side], let hip = s.hips[side],
                          [ankle,hip].allSatisfy({
                              [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                                && (0...1).contains($0.x) && (0...1).contains($0.y)
                          }), ankle.confidence >= 0.3, hip.confidence >= 0.5,
                          ankle.y > hip.y else { return nil }
                    let a = before.ankles[side]!, b = after.ankles[side]!
                    let expectedX = a.x+(b.x-a.x)*t, expectedY = a.y+(b.y-a.y)*t
                    guard hypot((ankle.x-expectedX)*aspect, ankle.y-expectedY) <= 0.2*scale else { return nil }
                }
                return s
            }
            // Old observations before a gap must not invalidate a complete,
            // continuous 200 ms approach that follows it. Never bridge the gap.
            if valid.count > 1, let lastGap = (1..<valid.count).last(where: {
                valid[$0].timestampMs-valid[$0-1].timestampMs > (toleratesPlantedApproachGap == true ? 134 : 110)
            }) { valid = Array(valid[lastGap...]) }
            // Corroborated weak views close a short confidence hole; they do
            // not replace the minimum number of confident observations.
            guard valid.filter({ strongTimes.contains($0.timestampMs) }).count >= 7 else { return false }
        }
        // The short impact window alone can make a genuine small kick look
        // stationary. Include at least 200 ms of the approach and a real view
        // after the reversal; never bridge a long hole in pose evidence.
        guard valid.count >= 7, valid.first!.timestampMs <= contactMs-200,
              valid.last!.timestampMs >= contactMs+25,
              zip(valid,valid.dropFirst()).allSatisfy({ $1.timestampMs-$0.timestampMs <= (toleratesPlantedApproachGap == true ? 134 : 110) }) else { return false }
        // Confidence filtering must not delete the contact and then infer
        // that the feet stayed planted across the resulting hole.
        guard !requiresImpact || valid.contains(where: { $0.timestampMs == contactMs }) else { return false }
        let clearApproach = valid.filter { s in
            s.timestampMs <= contactMs-50 && s.ballY+s.height/2
                < min(s.ankles[.left]!.y,s.ankles[.right]!.y)-0.1*scale
        }
        let nearFeet = valid.filter { s in
            abs(s.timestampMs-contactMs) <= 67 && s.ballY+s.height/2
                >= max(s.ankles[.left]!.y,s.ankles[.right]!.y)-0.25*scale
        }
        guard clearApproach.count >= 2, nearFeet.count >= 2 else { return false }
        // Quiet ankles are not proof of a floor bounce: a short toe flick can
        // be smoothed out by pose jitter filtering. Require the observed ball
        // center to reach the ankle line (within half a radius) as well. A ball
        // reversing clearly above that line has no positive floor evidence.
        if requiresLowBallCenter == true {
            guard nearFeet.contains(where: {
                $0.ballY >= max($0.ankles[.left]!.y,$0.ankles[.right]!.y)-0.25*scale
            }) else { return false }
        }
        return stableFeet(raw: valid, smoothed: valid, aspect: aspect, scale: scale)
    }

    /// Five or six real 15 FPS views can cover the same approach/release time
    /// as a dense window. Require every joint to be confident, a continuous
    /// 200 ms approach, a real release, and the existing motion bounds.
    private var confirmsSparsePlantedFeet: Bool {
        let ordered = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard (5...6).contains(ordered.count),
              Set(ordered.map(\.timestampMs)).count == ordered.count,
              let contact = ordered.first(where: { $0.timestampMs == contactMs }),
              ordered.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence,s.imageAspect].allSatisfy(\.isFinite)
                    && (0...1).contains(s.ballX) && (0...1).contains(s.ballY)
                    && s.width > 0 && s.width <= 1 && s.height > 0 && s.height <= 1
                    && s.confidence >= 0.5 && s.imageAspect > 0
                    && abs(s.imageAspect-contact.imageAspect) < 0.001
                    && (-350...150).contains(s.timestampMs-contactMs)
                    && BodySide.allCases.allSatisfy { side in
                        guard let ankle = s.ankles[side], let hip = s.hips[side] else { return false }
                        return [ankle,hip].allSatisfy {
                            [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                                && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.confidence >= 0.5
                        } && ankle.y > hip.y
                    }
              }),
              zip(ordered,ordered.dropFirst()).allSatisfy({ (40...75).contains($1.timestampMs-$0.timestampMs) }),
              let start = ordered.lastIndex(where: { $0.timestampMs <= contactMs-200 }),
              ordered[start].timestampMs >= contactMs-275,
              ordered.last!.timestampMs >= contactMs+50,
              ordered.map(\.height).max()! <= 1.35*ordered.map(\.height).min()!,
              ordered.map(\.width).max()! <= 1.35*ordered.map(\.width).min()! else { return false }
        let window = Array(ordered[start...])
        guard window.count >= 5 else { return false }
        let scale = median(ordered.map(\.height))
        let approach = window.filter {
            $0.timestampMs <= contactMs-50 && $0.ballY+$0.height/2
                < min($0.ankles[.left]!.y,$0.ankles[.right]!.y)-0.1*scale
        }
        let near = window.filter {
            abs($0.timestampMs-contactMs) <= 67 && $0.ballY+$0.height/2
                >= max($0.ankles[.left]!.y,$0.ankles[.right]!.y)-0.25*scale
        }
        guard approach.count >= 2, near.count >= 2,
              contact.ballY >= max(contact.ankles[.left]!.y,contact.ankles[.right]!.y)+0.1*scale,
              window.contains(where: { $0.timestampMs >= contactMs+50 && contact.ballY-$0.ballY >= 0.2*scale }) else { return false }
        // Older views still bound raw movement. Smooth only the complete
        // 200 ms approach/release window, never bridge or synthesize a frame.
        return stableFeet(raw: ordered, smoothed: window, aspect: contact.imageAspect, scale: scale)
    }

    private func stableFeet(raw: [Sample], smoothed: [Sample], aspect: Double, scale: Double) -> Bool {
        for side in BodySide.allCases {
            func image(_ views: [Sample]) -> [Vector] { views.map { s in
                Vector(x: s.ankles[side]!.x*aspect/scale, y: s.ankles[side]!.y/scale)
            } }
            func relative(_ views: [Sample]) -> [Vector] { views.map { s in
                let left = s.hips[.left]!, right = s.hips[.right]!, ankle = s.ankles[side]!
                return Vector(x: (ankle.x-(left.x+right.x)/2)*aspect/scale,
                              y: (ankle.y-(left.y+right.y)/2)/scale)
            } }
            // Require stability in BOTH image and pelvis-relative coordinates.
            // A whole-body jump or camera movement cannot establish planted feet.
            for (points, smoothingPoints) in [(image(raw),image(smoothed)),(relative(raw),relative(smoothed))] {
                guard diameter(points) <= 0.5 else { return false }
                let smoothed = (1..<smoothingPoints.count-1).map { i in
                    Vector(x: median(smoothingPoints[i-1...i+1].map(\.x)), y: median(smoothingPoints[i-1...i+1].map(\.y)))
                }
                // Median-of-three removes isolated ankle jitter; the raw-motion
                // bound above prevents smoothing away a large, real movement.
                guard diameter(smoothed) <= 0.2 else { return false }
            }
        }
        return true
    }

    private struct Vector { let x, y: Double }
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count/2]
    }
    private func diameter(_ points: [Vector]) -> Double {
        points.reduce(0) { result, a in
            max(result, points.map { hypot(a.x-$0.x,a.y-$0.y) }.max() ?? 0)
        }
    }
}
