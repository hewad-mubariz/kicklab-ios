import Foundation

/// Experimental proof for a shallow ball dip redirected by a lateral foot swing.
/// Uses the existing four measured views; it neither requests images nor relaxes
/// a floor verdict. All ordinary body, hand and holding checks still follow.
nonisolated enum ShallowLateralContactRules {
    static func confirms(_ evidence: FootContactEvidence) -> Bool {
        confirms(evidence, observedPlateau: false)
    }

    /// A complete measured turn can level off before the fourth pose view.
    /// Keep the same foot swing and separation proof, require the ball to stay
    /// wholly above the support ankle, and never infer a turn from pose alone.
    static func confirmsObservedPlateau(_ evidence: FootContactEvidence,
                                       turn: ObservedFallAmplitude.Turn) -> Bool {
        func matches(_ sample: FootContactRules.Sample, _ ball: BallObservation) -> Bool {
            sample.timestampMs == ball.timestampMs
                && abs(sample.ballX-ball.x) < 1e-9 && abs(sample.ballY-ball.y) < 1e-9
                && abs(sample.width-ball.width) < 1e-9 && abs(sample.height-ball.height) < 1e-9
        }
        guard matches(evidence.before, turn.approach), matches(evidence.contact, turn.contact),
              matches(evidence.after, turn.release) else { return false }
        return confirms(evidence, observedPlateau: true)
    }

    private static func confirms(_ evidence: FootContactEvidence, observedPlateau: Bool) -> Bool {
        let a = evidence.before, b = evidence.contact, c = evidence.after
        guard evidence.candidateTimestampMs == b.timestampMs,
              let d = evidence.continuation,
              (65...134).contains(b.timestampMs-a.timestampMs),
              (65...134).contains(c.timestampMs-b.timestampMs),
              (101...167).contains(d.timestampMs-b.timestampMs), d.timestampMs > c.timestampMs,
              let ground = evidence.compactGroundEvidence, ground.contactMs == b.timestampMs,
              !ground.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true),
              ground.unliftedFloorReboundMs == nil, ground.corroboratedFloorReboundMs == nil,
              MeasuredFootImpactRules.descendingFloorRebound(ground) == nil else { return false }
        let views = [a,b,c,d]
        guard views.allSatisfy({ s in
            [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                && s.width > 0 && s.height > 0 && (0.7...1).contains(s.confidence)
                && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
        }), views.map(\.width).max()! <= 1.35*views.map(\.width).min()!,
            views.map(\.height).max()! <= 1.35*views.map(\.height).min()!,
            b.ballY-a.ballY >= max(0.007,0.1*b.height),
            c.ballY-d.ballY >= (observedPlateau ? -0.0035 : 0.0035),
            !observedPlateau || (b.ballY-c.ballY >= 0.007 && b.ballY-d.ballY >= 0.007)
        else { return false }
        func reliable(_ p: PoseLandmark) -> Bool {
            [p.x,p.y,p.confidence].allSatisfy(\.isFinite)
                && (0...1).contains(p.x) && (0...1).contains(p.y)
                && (0.5...1).contains(p.confidence)
        }
        for side in BodySide.allCases {
            guard views.allSatisfy({ s in
                guard let ankle=s.ankles[side], let hip=s.hips[side],
                      let support=s.ankles[side.opposite] else { return false }
                return reliable(ankle) && reliable(hip) && reliable(support) && ankle.y > hip.y
            }) else { continue }
            let feet = views.map { $0.ankles[side]! }, hips = views.map { $0.hips[side]! }
            // Keep the ball center above the contacting ankle and its bottom
            // above the other ankle. A near-floor ball cannot use this route.
            guard (-0.5...0).contains((b.ballY-feet[1].y)/b.height),
                  hypot((b.ballX-feet[1].x)/b.width,(b.ballY-feet[1].y)/b.height) <= 0.75,
                  b.ballY+b.height/2 <= b.ankles[side.opposite]!.y else { continue }
            if observedPlateau, !views.allSatisfy({ s in
                s.ballY+s.height/2 <= s.ankles[side.opposite]!.y-0.2*b.height
            }) { continue }
            let travel = (feet[1].x-feet[0].x)/b.width
            let relative = ((feet[1].x-hips[1].x)-(feet[0].x-hips[0].x))/b.width
            guard abs(travel) >= 0.25, abs(relative) >= 0.25, travel*relative > 0,
                  travel*(b.ballX-feet[1].x) > 0,
                  (abs(a.ballX-feet[0].x)-abs(b.ballX-feet[1].x))/b.width >= 0.25 else { continue }
            let gap = zip(views,feet).map { $0.ballY-$1.y }
            guard gap[1]-gap[0] >= 0.1*b.height,
                  gap[1]-gap[2] >= max(0.007,0.12*b.height),
                  gap[1]-gap[3] >= max(0.007,0.15*b.height) else { continue }
            return true
        }
        return false
    }
}
