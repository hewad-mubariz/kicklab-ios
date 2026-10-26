import Foundation

/// Conservative evidence for a low foot contact when the body-box floor is
/// ambiguous. Three real ball observations must approach and leave the same
/// ankle. Relative coordinates remove body/camera translation; size stability,
/// timing and joint confidence are checked here. Unknown evidence cannot rescue a touch.
nonisolated enum FootContactRules {
    struct Sample: Codable, Equatable, Sendable {
        let timestampMs: Int
        let ballX, ballY, width, height, confidence: Double
        let ankles: [BodySide: Point]
        var hips: [BodySide: Point] = [:]
    }
    typealias Point = PoseLandmark
    static func confirms(before: Sample, contact: Sample, after: Sample,
                         requireBalancedMotion: Bool = true) -> Bool {
        let samples = [before, contact, after]
        let beforeMS = contact.timestampMs - before.timestampMs
        let afterMS = after.timestampMs - contact.timestampMs
        guard (40...130).contains(beforeMS), (40...130).contains(afterMS),
              samples.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                      && s.width > 0 && s.height > 0 && s.confidence >= 0.5
              }) else { return false }
        let heights = samples.map(\.height), widths = samples.map(\.width)
        guard heights.max()! <= heights.min()! * 1.35,
              widths.max()! <= widths.min()! * 1.35 else { return false }
        for side in BodySide.allCases {
            guard let a = before.ankles[side], let b = contact.ankles[side], let c = after.ankles[side],
                  [a.x,a.y,a.confidence,b.x,b.y,b.confidence,c.x,c.y,c.confidence].allSatisfy(\.isFinite),
                  min(a.confidence, min(b.confidence,c.confidence)) >= 0.3 else { continue }
            guard let beforeHip = before.hips[side], let contactHip = contact.hips[side],
                  [beforeHip.x,beforeHip.y,beforeHip.confidence,contactHip.x,contactHip.y,contactHip.confidence].allSatisfy(\.isFinite),
                  min(beforeHip.confidence,contactHip.confidence) >= 0.3 else { continue }
            // A ball bouncing beside stationary feet has an approach/release arc
            // too. Require resolved foot motion relative to the same hip, so
            // camera translation or a whole-body shift cannot supply the kick.
            let footDX = ((b.x-contactHip.x)-(a.x-beforeHip.x)) / contact.width
            let footDY = ((b.y-contactHip.y)-(a.y-beforeHip.y)) / contact.height
            let incomingFootTravel = hypot(footDX,footDY)
            if incomingFootTravel < max(0.15,0.007/contact.height) {
                // A small kick can develop gradually through the impact. The
                // incoming half alone can be below the motion floor even when
                // the full contact window contains resolved foot travel.
                // Require confident joints and aligned movement on BOTH halves;
                // stationary feet, whole-body shifts and reversing pose jitter
                // must not supply the missing evidence.
                guard let afterHip = after.hips[side],
                      [afterHip.x,afterHip.y,afterHip.confidence].allSatisfy(\.isFinite),
                      [a.confidence,b.confidence,c.confidence,beforeHip.confidence,
                       contactHip.confidence,afterHip.confidence].allSatisfy({ $0 >= 0.5 }) else { continue }
                let releaseDX = ((c.x-afterHip.x)-(b.x-contactHip.x)) / contact.width
                let releaseDY = ((c.y-afterHip.y)-(b.y-contactHip.y)) / contact.height
                let outgoingFootTravel = hypot(releaseDX,releaseDY)
                let halfFloor = max(0.05,0.0035/contact.height)
                guard incomingFootTravel >= halfFloor, outgoingFootTravel >= halfFloor,
                      // Weak approach evidence cannot be rescued by an ankle
                      // jump mainly AFTER impact. Compare speeds for unequal
                      // sampling intervals; v5 replay retains the old verdict.
                      !requireBalancedMotion || outgoingFootTravel/Double(afterMS)
                        <= 2*incomingFootTravel/Double(beforeMS) + 1e-12,
                      hypot(footDX+releaseDX,footDY+releaseDY) >= max(0.20,0.010/contact.height),
                      footDX*releaseDX+footDY*releaseDY >= 0.5*incomingFootTravel*outgoingFootTravel else { continue }
            }
            let dx = (contact.ballX - b.x) / contact.width
            let dy = (contact.ballY - b.y) / contact.height
            guard hypot(dx,dy) <= 0.75 else { continue }
            // A rolling ball passing alongside a moving foot is not an impact.
            // Require a resolved approach AND separation in ball diameters.
            let incoming = ((contact.ballY-b.y) - (before.ballY-a.y)) / contact.height
            let outgoing = ((contact.ballY-b.y) - (after.ballY-c.y)) / contact.height
            if incoming >= max(0.35,0.007/contact.height) && outgoing >= max(0.12,0.007/contact.height) { return true }
        }
        return false
    }


    /// An ankle near the ball moved at least `minimum` ball widths in image
    /// space: in one half of the contact, or gradually across both halves in
    /// the same direction (the same shape the hip-relative rule accepts).
    /// Hip-relative travel can be assembled from ankle and hip jitter while
    /// nothing moved, and jitter reverses between halves; this cannot pass.
    static func ankleTravels(_ evidence: FootContactEvidence, minimum: Double = 0.2) -> Bool {
        let before = evidence.before, contact = evidence.contact
        guard contact.width > 0, contact.height > 0 else { return false }
        for side in BodySide.allCases {
            guard let a = before.ankles[side], let b = contact.ankles[side],
                  [a.x,a.y,a.confidence,b.x,b.y,b.confidence].allSatisfy(\.isFinite),
                  min(a.confidence, b.confidence) >= 0.5,
                  hypot((contact.ballX-b.x)/contact.width, (contact.ballY-b.y)/contact.height) <= 0.75 else { continue }
            let inX = (b.x-a.x)/contact.width, inY = (b.y-a.y)/contact.height
            var outX = 0.0, outY = 0.0
            if let c = evidence.after.ankles[side], [c.x,c.y,c.confidence].allSatisfy(\.isFinite), c.confidence >= 0.5 {
                outX = (c.x-b.x)/contact.width; outY = (c.y-b.y)/contact.height
            }
            let incoming = hypot(inX, inY), outgoing = hypot(outX, outY)
            if max(incoming, outgoing) >= minimum { return true }
            // Gradual: both halves resolved, aligned, and adding up to the minimum.
            if incoming >= 0.05, outgoing >= 0.05,
               inX*outX+inY*outY >= 0.5*incoming*outgoing,
               hypot(inX+outX, inY+outY) >= minimum { return true }
        }
        return false
    }

    /// Positive stationary-foot evidence for the additional lower-edge ground
    /// gate. Uncertain pose is not evidence that the feet stayed on the floor.
    static func stationaryFeet(_ evidence: FootContactEvidence) -> Bool {
        let samples = [evidence.before, evidence.contact, evidence.after]
        let contact = evidence.contact
        guard (40...130).contains(contact.timestampMs-evidence.before.timestampMs),
              (40...130).contains(evidence.after.timestampMs-contact.timestampMs),
              samples.allSatisfy({
                  [$0.width,$0.height,$0.confidence].allSatisfy(\.isFinite)
                    && $0.width > 0 && $0.height > 0 && $0.confidence >= 0.5
              }), samples.map(\.height).max()! <= 1.35*samples.map(\.height).min()!,
              samples.map(\.width).max()! <= 1.35*samples.map(\.width).min()! else { return false }
        for side in BodySide.allCases {
            var relative: [(Double,Double)] = []
            for sample in samples {
                guard let ankle = sample.ankles[side], let hip = sample.hips[side],
                      [ankle,hip].allSatisfy({
                          [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite) && $0.confidence >= 0.5
                      }) else { return false }
                relative.append(((ankle.x-hip.x)/contact.width, (ankle.y-hip.y)/contact.height))
            }
            // Include the full window: two small steps cannot hide a kick.
            for i in relative.indices {
                for j in relative.indices where j > i {
                    if hypot(relative[i].0-relative[j].0, relative[i].1-relative[j].1) > 0.1 { return false }
                }
            }
        }
        return true
    }
}

nonisolated struct FootContactEvidence: Codable, Equatable, Sendable {
    let before, contact, after: FootContactRules.Sample
    /// A real later view already buffered at sparse cadence. Older traces omit it.
    var continuation: FootContactRules.Sample? = nil
    var confirms: Bool { FootContactRules.confirms(before: before, contact: contact, after: after) }

    /// The ankle is behind the toes. A larger contact area is usable only with
    /// a confidently rising foot, a stable opposite support, and a resolved
    /// ball approach/release. This is a sparse-cadence fallback, not proximity alone.
    var confirmsExtendedMotion: Bool {
        [after, continuation].compactMap { $0 }.contains { release in
            let views = [before, contact, release]
            let incomingMS = contact.timestampMs-before.timestampMs
            let outgoingMS = release.timestampMs-contact.timestampMs
            guard (40...150).contains(incomingMS), (40...167).contains(outgoingMS),
                  views.allSatisfy({ s in
                      [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains(s.ballX) && (0...1).contains(s.ballY)
                        && s.width > 0 && s.width <= 1 && s.height > 0 && s.height <= 1 && s.confidence >= 0.5
                        && BodySide.allCases.allSatisfy { side in
                            guard let ankle = s.ankles[side], let hip = s.hips[side] else { return false }
                            return [ankle,hip].allSatisfy {
                                [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                                    && (0...1).contains($0.x) && (0...1).contains($0.y) && $0.confidence >= 0.5
                            } && ankle.y > hip.y
                        }
                  }),
                  views.map(\.height).max()! <= 1.35*views.map(\.height).min()!,
                  views.map(\.width).max()! <= 1.35*views.map(\.width).min()! else { return false }
            for side in BodySide.allCases {
                let ankles = views.map { $0.ankles[side]! }, hips = views.map { $0.hips[side]! }
                let support = views.map { s -> (Double,Double) in
                    let a = s.ankles[side.opposite]!, h = s.hips[side.opposite]!
                    return ((a.x-h.x)/contact.width,(a.y-h.y)/contact.height)
                }
                guard support.allSatisfy({ a in support.allSatisfy { hypot(a.0-$0.0,a.1-$0.1) <= 0.15 } }),
                      hips.allSatisfy({ a in hips.allSatisfy { hypot((a.x-$0.x)/contact.width,(a.y-$0.y)/contact.height) <= 0.2 } }),
                      ankles[1].y <= contact.ankles[side.opposite]!.y-0.1*contact.height,
                      hypot((contact.ballX-ankles[1].x)/contact.width,
                            (contact.ballY-ankles[1].y)/contact.height) <= 1.25 else { continue }
                let upBefore = ((ankles[0].y-hips[0].y)-(ankles[1].y-hips[1].y))/contact.height
                let upAfter = ((ankles[1].y-hips[1].y)-(ankles[2].y-hips[2].y))/contact.height
                let across = ((ankles[2].x-hips[2].x)-(ankles[0].x-hips[0].x))/contact.width
                guard upBefore >= 0.05, upAfter >= 0.05,
                      hypot(across,upBefore+upAfter) >= max(0.2,0.010/contact.height),
                      upAfter/Double(outgoingMS) <= 2*upBefore/Double(incomingMS) else { continue }
                let incoming = ((contact.ballY-ankles[1].y)-(before.ballY-ankles[0].y))/contact.height
                let outgoing = ((contact.ballY-ankles[1].y)-(release.ballY-ankles[2].y))/contact.height
                if incoming >= max(0.35,0.007/contact.height), outgoing >= max(0.12,0.007/contact.height) { return true }
            }
            return false
        }
    }
}
