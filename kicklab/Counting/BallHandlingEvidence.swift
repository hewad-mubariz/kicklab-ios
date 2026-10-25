import Foundation

/// A local temporal state at a proposed contact, measured from observed images.
/// It expires with this window: a catch must never leave a sticky veto on later kicks.
nonisolated struct BallHandlingEvidence: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case held, inPlay, uncertain }
    struct Sample: Codable, Equatable, Sendable {
        let timestampMs: Int
        let ball: PosePoint
        let width, height, confidence, imageAspect: Double
        let wrists: [BodySide: PoseLandmark]
    }
    let contactMs: Int
    let samples: [Sample]
    /// A recovered candidate keeps its trajectory time while the grip test
    /// stays centered on the actual observed leg contact. Nil in old traces.
    var observedImpactMs: Int? = nil
    /// Versioned so archived evidence retains its original interpretation.
    var bridgesGripJitter: Bool? = nil

    var state: State {
        let contactMs = observedImpactMs ?? self.contactMs
        let views = samples.filter { (-200...150).contains($0.timestampMs-contactMs) }
            .sorted { $0.timestampMs < $1.timestampMs }
        guard let contact = views.firstIndex(where: { $0.timestampMs == contactMs }),
              views.allSatisfy(Self.usable),
              zip(views,views.dropFirst()).allSatisfy({ $0.timestampMs < $1.timestampMs }) else { return .uncertain }
        // Unknown wrists or a tracking hole cannot be bridged into a grip.
        var lo = contact, hi = contact
        let toleratesJitter = bridgesGripJitter == true
        guard Self.grip(views[contact], tolerance: toleratesJitter ? 1.25 : 1.15) else {
            let clear = views.filter { view in
                BodySide.allCases.allSatisfy { side in
                    guard let wrist = view.wrists[side], wrist.confidence >= 0.5 else { return false }
                    return Self.distance(wrist, view) > 1.5
                }
            }
            return clear.count >= 3 && clear.first!.timestampMs <= contactMs-50
                && clear.last!.timestampMs >= contactMs+50 ? .inPlay : .uncertain
        }
        let reference = views[contact]
        func coupled(_ view: Sample) -> Bool {
            guard Self.grip(view, tolerance: toleratesJitter ? 1.25 : 1.15) else { return false }
            return BodySide.allCases.allSatisfy { side in
                let origin = Self.offset(reference.wrists[side]!,reference)
                let offset = Self.offset(view.wrists[side]!,view)
                return hypot(offset.x-origin.x,offset.y-origin.y) <= 0.3
            }
        }
        while lo > 0, views[lo].timestampMs-views[lo-1].timestampMs <= 100,
              coupled(views[lo-1]) { lo -= 1 }
        while hi+1 < views.count, views[hi+1].timestampMs-views[hi].timestampMs <= 100,
              coupled(views[hi+1]) { hi += 1 }
        let run = Array(views[lo...hi])
        if toleratesJitter {
            // A brief threshold crossing is allowed only inside a sustained,
            // coupled grip observed strictly on BOTH sides. This cannot bridge
            // a missing wrist, a release, or a catch after a genuine kick.
            let strict = run.filter { Self.grip($0) }
            guard strict.count >= 4,
                  strict.contains(where: { (contactMs-150...contactMs-1).contains($0.timestampMs) }),
                  strict.contains(where: { (contactMs+1...contactMs+150).contains($0.timestampMs) }) else { return .uncertain }
            var weakStart: Int?, weakCount = 0
            for view in run {
                if Self.grip(view) { weakStart = nil; weakCount = 0; continue }
                weakStart = weakStart ?? view.timestampMs; weakCount += 1
                guard weakCount <= 2, view.timestampMs-weakStart! <= 67 else { return .uncertain }
            }
        }
        guard run.count >= 4, contactMs-run[0].timestampMs >= 50,
              run.last!.timestampMs-contactMs >= 50,
              run.last!.timestampMs-run[0].timestampMs >= 150,
              run.map(\.height).max()! <= 1.25*run.map(\.height).min()!,
              run.map(\.width).max()! <= 1.25*run.map(\.width).min()! else { return .uncertain }
        return .held
    }

    private static func usable(_ s: Sample) -> Bool {
        [s.ball.x,s.ball.y,s.width,s.height,s.confidence,s.imageAspect].allSatisfy(\.isFinite)
            && s.width > 0 && s.height > 0 && s.imageAspect > 0 && s.confidence >= 0.5
            && s.wrists.values.allSatisfy { [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite) }
    }
    private static func offset(_ wrist: PoseLandmark, _ s: Sample) -> PosePoint {
        let diameter = max(s.width*s.imageAspect,s.height)
        return .init(x: (wrist.x-s.ball.x)*s.imageAspect/diameter, y: (wrist.y-s.ball.y)/diameter)
    }
    private static func distance(_ wrist: PoseLandmark, _ s: Sample) -> Double {
        let delta = offset(wrist,s)
        return hypot(delta.x,delta.y)
    }
    private static func grip(_ s: Sample, tolerance: Double = 1.15) -> Bool {
        guard let left = s.wrists[.left], let right = s.wrists[.right],
              left.confidence >= 0.5, right.confidence >= 0.5,
              distance(left,s) <= tolerance, distance(right,s) <= tolerance else { return false }
        let l = offset(left,s), r = offset(right,s)
        // The wrists bracket the ball, allowing hands/fingers beyond the wrist
        // endpoints. Merely having two arms on the same side is insufficient.
        return l.x*r.x <= 0 && hypot(l.x-r.x,l.y-r.y) <= 1.6
    }
}
