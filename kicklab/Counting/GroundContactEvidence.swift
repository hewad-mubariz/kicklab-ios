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

    /// Only sparse impact tracks take the extra foot-proof route. Continuous
    /// low taps keep their existing rules. Rechecked images must be excluded:
    /// they can establish floor evidence but do not erase the original gap.
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
        guard requiresPositiveLowContact == true else { return false }
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

    static let signature = "|cadence-ground-v2"

    func confirmsGroundContact(corroboratingWeakAnkles: Bool, cadenceAware: Bool = false) -> Bool {
        confirmsPlantedFeet(corroboratingWeakAnkles: corroboratingWeakAnkles)
            || (checksBallBelowFeet == true && confirmsBallBelowFeet)
            || (cadenceAware && confirmsSparsePlantedFeet)
            || (checksDeepFloorContact == true && confirmsDeepFloorContact)
    }

    /// The ball's lower edge is at least half a ball height below the lower of
    /// two confident, planted ankles and between them, after at least two
    /// approach views above both ankles, with a rebound. The ankles must stay
    /// within 0.15 ball heights across every confident view within 67 ms, so a
    /// foot that could have cushioned or kicked the ball disqualifies the proof.
    /// Measured against 3,158 accepted touches with floor evidence: zero legal
    /// contacts reach this geometry; eight reviewed carpet bounces do.
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

    func confirmsPlantedFeet(corroboratingWeakAnkles: Bool) -> Bool {
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
