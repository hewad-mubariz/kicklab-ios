#if DEBUG
import CoreGraphics
import Foundation

/// The 3 x 2 target board on the wall, mapped from the camera image through its
/// four outer corners. Board coordinates run u 0...3 left to right and v 0...2
/// top to bottom, so box = row * 3 + column + 1.
nonisolated struct WallBoard: Equatable, Sendable {
    let corners: [CGPoint]   // image pixels, top-left origin: TL, TR, BR, BL
    private let toBoard: [Double]
    private let toImage: [Double]

    init?(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let image = [topLeft, topRight, bottomRight, bottomLeft]
        guard Self.isConvex(image) else { return nil }
        let board = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 2), CGPoint(x: 0, y: 2)]
        guard let forward = Self.homography(from: image, to: board),
              let inverse = Self.homography(from: board, to: image) else { return nil }
        corners = image; toBoard = forward; toImage = inverse
    }

    func boardPoint(_ p: CGPoint) -> CGPoint { Self.apply(toBoard, p) }
    func imagePoint(u: Double, v: Double) -> CGPoint { Self.apply(toImage, CGPoint(x: u, y: v)) }

    /// Box 1...6 for a board point, or nil outside the grid.
    static func box(u: Double, v: Double) -> Int? {
        guard (0...3).contains(u), (0...2).contains(v) else { return nil }
        return min(1, Int(v)) * 3 + min(2, Int(u)) + 1
    }

    /// A measured centre close enough to a line to change boxes under the
    /// tracking/alignment error is neutral. This is not a ball-radius overlap rule.
    func isBorderline(_ point: CGPoint, uncertainty: Double) -> Bool {
        guard uncertainty > 0, uncertainty.isFinite else { return false }
        let centre = boardPoint(point)
        let box = Self.box(u: centre.x, v: centre.y)
        for i in 0..<16 {
            let angle = Double(i) * .pi / 8
            let p = boardPoint(CGPoint(x: point.x + cos(angle) * uncertainty,
                                      y: point.y + sin(angle) * uncertainty))
            if Self.box(u: p.x, v: p.y) != box { return true }
        }
        return false
    }

    /// A saved rectangle is only a hint. Callers must explicitly confirm a fresh
    /// calibration; this check rejects crossed, collapsed and off-screen handles.
    static func validCalibration(_ points: [CGPoint]) -> Bool {
        guard isConvex(points), points.allSatisfy({
            (0...1).contains($0.x) && (0...1).contains($0.y)
        }) else { return false }
        let area = (0..<4).reduce(0.0) {
            $0 + points[$1].x * points[($1 + 1) % 4].y - points[($1 + 1) % 4].x * points[$1].y
        } / 2
        return area >= 0.02
    }

    private static func isConvex(_ points: [CGPoint]) -> Bool {
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        return (0..<4).allSatisfy { i in
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 1e-9
        }
    }

    private static func apply(_ h: [Double], _ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y), w = h[6] * x + h[7] * y + 1
        return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w, y: (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// The 8 coefficients (h33 = 1) of the projective map taking `src` to `dst`.
    static func homography(from src: [CGPoint], to dst: [CGPoint]) -> [Double]? {
        guard src.count == 4, dst.count == 4,
              (src + dst).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var rows: [[Double]] = []
        for (s, d) in zip(src, dst) {
            let x = Double(s.x), y = Double(s.y), u = Double(d.x), v = Double(d.y)
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        // Gaussian elimination with partial pivoting on the 8 x 9 augmented system.
        for c in 0..<8 {
            guard let pivot = (c..<8).max(by: { abs(rows[$0][c]) < abs(rows[$1][c]) }),
                  abs(rows[pivot][c]) > 1e-9 else { return nil }
            rows.swapAt(c, pivot)
            for r in 0..<8 where r != c {
                let k = rows[r][c] / rows[c][c]
                for j in c...8 { rows[r][j] -= k * rows[c][j] }
            }
        }
        let h = (0..<8).map { rows[$0][8] / rows[$0][$0] }
        return h.allSatisfy(\.isFinite) ? h : nil
    }
}

/// Fixed-camera rules v5: measured wall depth, longer rebound evidence, contact anchored to the size minimum.
///
/// A wall hit is the ball reaching wall depth (its apparent size bottoms out
/// near the explicitly sampled wall size) and then turning back. At that instant it is
/// close to the wall plane, so the board homography estimates its box. The
/// ball centre still has parallax at oblique angles; this is coarse box scoring.
/// Evidence windows use elapsed time. The size valley is checked over a full
/// contact neighbourhood. Rebound confirmation can arrive later than the
/// contact: sparse live measurements need up to 0.4 seconds to establish it.
/// Scoring waits for measured evidence on both sides; it never
/// uses a predicted crossing or the later strongest turn as the hit location.
nonisolated struct WallImpactDetector: Sendable {
    struct Observation: Equatable, Sendable {
        var t, x, y, d: Double
        var hand: WallHandState = .unknown
    }   // seconds; pixels
    struct Impact: Equatable, Sendable {
        var t, x, y, d, turn, u, v: Double
        var box: Int?
        var borderline = false
    }
    struct Decision: Sendable { var t, x, y, d: Double; var reason: String }
    private var decisions: [Decision] = []

    mutating func takeDecisions() -> [Decision] {
        let result = decisions; decisions.removeAll(keepingCapacity: true); return result
    }

    static let maxGap = 10.0 / 60, approachWindow = 0.25, turnWindow = 7.0 / 60
    static let kinkSearch = 4.0 / 60, regrowWindow = 0.40, minSeparation = 20.0 / 60
    static let turnDegrees = 50.0, approachShrink = 0.12
    // Keep the existing response time when evidence is already sufficient.
    // Incomplete rebounds wait for the full confirmation window below.
    static let settle = maxGap + turnWindow + kinkSearch + 0.05
    private static let historySpan = 3.0

    var board: WallBoard
    /// Observation cadence; below 50 fps v2 accepts one fewer approach/side point.
    var processingFPS = 60.0
    /// Enabled by the live aligned-board pipeline; legacy detector replays can
    /// still inspect all physical contacts without classifying target uncertainty.
    var rejectBorderline = false
    private(set) var history: [Observation] = []
    let reference: WallBallReference?
    let imageWidth: Double
    private var lastImpact = -Double.infinity
    private var judgedThrough = -Double.infinity

    init(board: WallBoard, reference: WallBallReference? = nil, imageWidth: Double = 1) {
        self.board = board; self.reference = reference; self.imageWidth = imageWidth
    }

    /// No warmup fallback: an arbitrary nearby ball can never establish wall depth.
    var wallGate: Double { (reference?.diameters.max() ?? 0) * imageWidth * 1.25 }

    func isAtWall(_ o: Observation) -> Bool {
        guard let reference, imageWidth.isFinite, imageWidth > 0 else { return false }
        let p = board.boardPoint(CGPoint(x: o.x, y: o.y))
        guard p.x.isFinite, p.y.isFinite else { return false }
        let expected = reference.diameter(u: p.x, v: p.y, imageWidth: imageWidth)
        return o.d >= expected * 0.70 && o.d <= expected * 1.25
    }

    mutating func add(_ observation: Observation) {
        guard [observation.t, observation.x, observation.y, observation.d].allSatisfy(\.isFinite),
              observation.d > 0, history.last.map({ observation.t > $0.t }) ?? true else { return }
        history.append(observation)
        if let first = history.firstIndex(where: { observation.t - $0.t <= Self.historySpan }), first > 0 {
            history.removeFirst(first)
        }
    }

    /// Hits whose evidence is complete at `now`. Pass `.infinity` to flush.
    mutating func impacts(now: Double) -> [Impact] {
        impacts(now: now, settling: turnEvidenceMaturity, requireTurnBeforeSettle: true)
    }

    /// A visual acknowledgement only. The full turn neighbourhood must already
    /// have arrived, and all depth, release and rebound gates still apply. Probe
    /// a value copy so tentative evidence cannot consume or alter a scored hit.
    func previewContacts(now: Double) -> [Impact] {
        var probe = self
        return probe.impacts(now: now, settling: turnEvidenceMaturity)
    }

    private var turnEvidenceMaturity: Double {
        let slack = 0.5 / max(processingFPS, 1)
        return min(Self.settle, max(0.10 + slack, Self.kinkSearch + Self.turnWindow + 2 * slack))
    }

    private mutating func impacts(now: Double, settling: Double, requireTurnBeforeSettle: Bool = false) -> [Impact] {
        guard reference != nil else { return [] }
        let minBefore = processingFPS >= 50 ? 4 : 3, minSide = processingFPS >= 50 ? 3 : 2
        // Half a frame: makes each seconds window include exactly the frame counts
        // v2 used at 30 and 60 fps (where 7 frames at 60 fps rounded to 4 at 30).
        let slack = 0.5 / max(processingFPS, 1), gate = wallGate
        var found: [Impact] = []
        for track in tracks() {
            guard track.count >= 5 else { continue }
            for i in 2..<(track.count - 2) {
                let m = track[i]
                guard m.t > judgedThrough, m.t <= now - settling else { continue }
                let previouslyJudged = judgedThrough
                judgedThrough = m.t
                // A five-frame minimum can be a size wobble while the ball is
                // still approaching (especially at 60 fps). Wait for the whole
                // contact neighbourhood before committing to that minimum.
                let valley = track.filter { abs($0.t - m.t) <= 0.10 + slack }
                guard m.d == valley.map(\.d).min() else { continue }
                var reason = "wall_size"
                defer {
                    let p = board.boardPoint(CGPoint(x: m.x, y: m.y))
                    if (-0.3...3.3).contains(p.x), (-0.3...2.3).contains(p.y), decisions.count < 5000 {
                        decisions.append(Decision(t: m.t, x: m.x, y: m.y, d: m.d, reason: reason))
                    }
                }
                guard isAtWall(m) else { continue }
                reason = "approach"
                let before = track[...i].filter { m.t - $0.t <= Self.approachWindow + slack }
                guard before.count >= minBefore,
                      before.map(\.d).max()! >= m.d * (1 + Self.approachShrink),
                      Self.slope(before) < 0 else { continue }   // shrinking on the way in, not a size glitch
                // The size minimum is noisy; the kink is the sharpest turn near it.
                var best: (turn: Double, pre: [Observation], post: [Observation], k: Int)?
                // The chosen contact must satisfy the same depth gate as the
                // minimum. A neighbouring, oversized box is not a wall contact.
                for k in track.indices where abs(track[k].t - m.t) <= Self.kinkSearch + slack
                    && isAtWall(track[k]) && track[k].d <= m.d * 1.25 {
                    let r = Self.turn(track, at: k, minSide: minSide, slack: slack)
                    if best == nil || r.turn > best!.turn { best = (r.turn, r.pre, r.post, k) }
                }
                guard let best else { continue }
                // A frontal camera sees the bounce mostly as depth: size dips, then recovers.
                let later = track[(i + 1)...].filter { $0.t - m.t <= Self.regrowWindow + slack }.map(\.d)
                let regrow = (later.max() ?? m.d) / m.d - 1
                // Near-frontal shots can reverse in depth without a visible 2D
                // turn. Require a sustained size recovery, not a one-frame spike.
                let after = track[(i + 1)...].filter { $0.t - m.t <= Self.regrowWindow + slack }
                let shrinkingSteps = zip(before, before.dropFirst()).filter { $0.d - $1.d >= m.d * 0.015 }.count
                let growingSteps = zip([m] + after, after).filter { $1.d - $0.d >= m.d * 0.015 }.count
                let depthRebound = gate.isFinite && after.filter { $0.d >= m.d * 1.12 }.count >= minSide
                    && shrinkingSteps >= 2 && growingSteps >= 2
                    && Self.slope(after) > 0
                let turned = best.turn >= Self.turnDegrees || (regrow >= 0.08 && best.turn >= 20)
                let location = board.boardPoint(CGPoint(x: m.x, y: m.y))
                let fu = location.x - floor(location.x), fv = location.y - floor(location.y)
                let clearlyInside = WallBoard.box(u: location.x, v: location.y) != nil
                    && min(fu, 1 - fu, fv, 1 - fv) >= 0.15
                reason = "rebound"
                if requireTurnBeforeSettle, now < m.t + Self.settle, !turned || !clearlyInside {
                    // The complete 2D turn window can confirm early. A depth-only
                    // recovery or a contact near a boundary keeps the full window.
                    judgedThrough = previouslyJudged
                    reason = "rebound_pending"
                    return found
                }
                guard turned || depthRebound else {
                    if now < m.t + Self.regrowWindow + slack {
                        // Do not let a later point replace this contact while
                        // its outgoing evidence can still arrive. Keep its
                        // measured position and re-evaluate on the next frame.
                        judgedThrough = previouslyJudged
                        reason = "rebound_pending"
                        return found
                    }
                    continue
                }
                // A turn corroborates the bounce, but its sharpest observed point can
                // be on the outgoing path. Never move the contact into that box.
                let p = m
                // Neither a hand-held wall reference nor a catch is a shot. Unknown
                // pose evidence cannot silently become proof of a released ball.
                let freeBefore = track.filter { p.t - $0.t >= 0 && p.t - $0.t <= Self.approachWindow + slack && $0.hand == .clear }
                let freeAfter = track.filter { $0.t >= p.t && $0.t - p.t <= Self.regrowWindow + slack && $0.hand == .clear }
                reason = "hands"
                guard p.hand == .clear, freeBefore.count >= 1, freeAfter.count >= 2 else {
                    if requireTurnBeforeSettle, p.hand == .clear, now < m.t + Self.settle {
                        judgedThrough = previouslyJudged
                        reason = "hands_pending"
                        return found
                    }
                    continue
                }
                reason = "cooldown"
                guard p.t - lastImpact >= Self.minSeparation - slack else { continue }
                let point = CGPoint(x: p.x, y: p.y)
                let b = board.boardPoint(point)
                guard b.x.isFinite, b.y.isFinite else { continue }
                lastImpact = p.t
                let borderline = rejectBorderline && board.isBorderline(point, uncertainty: 3 + max(3, p.d * 0.15))
                reason = borderline ? "borderline" : "accepted"
                found.append(Impact(t: p.t, x: point.x, y: point.y, d: p.d, turn: best.turn,
                                    u: b.x, v: b.y, box: borderline ? nil : WallBoard.box(u: b.x, v: b.y),
                                    borderline: borderline))
            }
        }
        return found
    }

    /// Consecutive observations with short gaps and plausible jumps.
    private func tracks() -> [[Observation]] {
        let frame = 1 / max(processingFPS, 1)
        var result: [[Observation]] = [], current: [Observation] = []
        for o in history {
            if let last = current.last {
                let dt = o.t - last.t
                if dt > Self.maxGap + 1.5 * frame ||
                    hypot(o.x - last.x, o.y - last.y) > 1.5 * last.d * max(1, dt * processingFPS) {
                    result.append(current); current = []
                }
            }
            current.append(o)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func turn(_ track: [Observation], at k: Int, minSide: Int, slack: Double)
        -> (turn: Double, pre: [Observation], post: [Observation]) {
        let c = track[k]
        let pre = track[...k].filter { c.t - $0.t <= turnWindow + slack }
        let post = track[k...].filter { $0.t - c.t <= turnWindow + slack }
        guard pre.count >= minSide, post.count >= minSide else { return (0, pre, post) }
        let vin = (c.x - pre[0].x, c.y - pre[0].y), vout = (post.last!.x - c.x, post.last!.y - c.y)
        let nin = hypot(vin.0, vin.1), nout = hypot(vout.0, vout.1)
        guard nin >= max(2, c.d * 0.35), nout >= max(2, c.d * 0.35) else { return (0, pre, post) }
        let cosine = max(-1, min(1, (vin.0 * vout.0 + vin.1 * vout.1) / (nin * nout)))
        return (acos(cosine) * 180 / .pi, pre, post)
    }

    private static func slope(_ ps: [Observation]) -> Double {
        let mt = ps.map(\.t).reduce(0, +) / Double(ps.count), md = ps.map(\.d).reduce(0, +) / Double(ps.count)
        let den = ps.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
        return den > 0 ? ps.reduce(0) { $0 + ($1.t - mt) * ($1.d - md) } / den : 0
    }

}
#endif
