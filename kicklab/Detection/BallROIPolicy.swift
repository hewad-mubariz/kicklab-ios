import Foundation

/// Source pixels, top-left origin. This value never represents a prediction.
nonisolated struct ROICandidate: Codable, Equatable {
    var box: [Double]
    var score: Double
    var x: Double { (box[0] + box[2]) / 2 }
    var y: Double { (box[1] + box[3]) / 2 }
    var width: Double { box[2] - box[0] }
    var height: Double { box[3] - box[1] }
    var diameter: Double { max(width, height) }
    var valid: Bool {
        box.count == 4 && box.allSatisfy(\.isFinite) && score.isFinite
            && (0...1).contains(score) && width > 0 && height > 0
    }
}

nonisolated struct ROIView: Codable, Equatable {
    var rect: [Int]
    var mode: String
    var reason: String
    var timestamp: Double
    var isFull: Bool { mode == "full" }
    var width: Int { rect[2] - rect[0] }
    var height: Int { rect[3] - rect[1] }
}

/// Exact port of the frozen Python v3 policy. One chosen view per timestamp;
/// never substitutes extrapolated positions for actual detector observations.
nonisolated final class BallROIPolicy {
    private var last: ROICandidate?
    private var lastSeen = -Double.infinity, lastStrong = -Double.infinity
    private var vx = 0.0, vy = 0.0
    private var trustedHits = 0, misses = 0
    private var confirmed = false, smallMode = false
    private var lastFull = -Double.infinity, lastTime = -Double.infinity
    private var width = 0, height = 0
    private var sizes: [(time: Double, size: Double)] = []
    private var switchCandidate: ROICandidate?
    private var switchTime = -Double.infinity
    private var switchHits = 0
    private var pending: ROIView?

    enum Failure: Error { case ordering, timestamp, dimensions }

    private func clearSwitch() {
        switchCandidate = nil; switchTime = -.infinity; switchHits = 0
    }
    private func forget() {
        last = nil; vx = 0; vy = 0; trustedHits = 0; confirmed = false; misses = 0
        lastSeen = -.infinity; lastStrong = -.infinity
        sizes.removeAll(keepingCapacity: true); smallMode = false; clearSwitch()
    }
    private func predict(_ t: Double) -> (Double, Double) {
        let dt = min(t - lastSeen, 0.10)
        return (last!.x + vx * dt, last!.y + vy * dt)
    }
    private func rounded(_ value: Double) -> Int { Int(value.rounded(.toNearestOrEven)) }

    func choose(timestamp t: Double, width w: Int, height h: Int,
                sceneChange: Bool = false) throws -> ROIView {
        guard pending == nil else { throw Failure.ordering }
        guard t.isFinite, t > lastTime else { throw Failure.timestamp }
        guard w > 0, h > 0 else { throw Failure.dimensions }
        if sceneChange || width != w || height != h {
            forget(); lastFull = -.infinity
        }
        width = w; height = h; lastTime = t
        if last != nil && (t - lastSeen > 0.25 || t - lastStrong > 0.5) { forget() }
        var view = ROIView(rect: [0, 0, w, h], mode: "full", reason: "acquire", timestamp: t)
        if let last, confirmed {
            let (cx, cy) = predict(t)
            if misses >= 2 { view.reason = "reacquire_after_misses" }
            else if t - lastSeen > 0.10 { view.reason = "prediction_expired" }
            else if cx < 0 || cx >= Double(w) || cy < 0 || cy >= Double(h) {
                view.reason = "prediction_outside_image"
            } else if t - lastFull >= 0.4 { view.reason = "periodic_full_scan" }
            else {
                let side = rounded(max(Double(max(w, h)) * 0.4, last.diameter * 6))
                if Double(side) >= 0.95 * Double(min(w, h)) {
                    view.reason = "large_ball_or_narrow_image"
                } else {
                    let side = max(1, min(side, w, h))
                    let x = max(0, min(w - side, rounded(cx - Double(side) / 2)))
                    let y = max(0, min(h - side, rounded(cy - Double(side) / 2)))
                    view.rect = [x, y, x + side, y + side]
                    view.mode = "crop"; view.reason = "recent_confirmed_motion"
                }
            }
        }
        if view.isFull { lastFull = t }
        sizes.removeAll { t - $0.time > 0.2 }
        if let last {
            if last.diameter / Double(max(w, h)) >= 30.0 / 416 { smallMode = false }
            else if sizes.count >= 2 {
                let a = sizes[sizes.count - 2], b = sizes[sizes.count - 1]
                if b.time - a.time <= 0.10 && t - b.time <= 0.10
                    && max(a.size, b.size) <= 24.0 / 416 { smallMode = true }
            }
        }
        if !view.isFull && !smallMode {
            view = ROIView(rect: [0, 0, w, h], mode: "full",
                           reason: "nearby_ball_keep_context", timestamp: t)
            lastFull = t
        }
        pending = view
        return view
    }

    private func switchConfirmed(_ d: ROICandidate, _ t: Double) -> Bool {
        var consistent = false
        if let old = switchCandidate, t - switchTime <= 0.1 {
            let gate = max(2.5 * old.diameter, hypot(Double(width), Double(height)) * 2.5 * (t - switchTime))
            consistent = hypot(d.x - old.x, d.y - old.y) <= gate
                && (0.5...2).contains(d.width / old.width)
                && (0.5...2).contains(d.height / old.height)
        }
        switchHits = consistent ? switchHits + 1 : 1
        switchCandidate = d; switchTime = t
        return switchHits >= 2
    }

    func observe(_ candidates: [ROICandidate]) throws -> (ROICandidate?, String) {
        guard let view = pending else { throw Failure.ordering }
        pending = nil
        let t = view.timestamp
        let valid = candidates.filter {
            $0.valid && $0.score >= 0.10 && $0.box[0] >= 0 && $0.box[1] >= 0
                && $0.box[2] <= Double(width) && $0.box[3] <= Double(height)
        }
        var selected: ROICandidate?
        var reason = valid.isEmpty ? "no_candidate" : "association_rejected"
        var switched = false
        if let old = last {
            let dt = max(t - lastSeen, 1e-6), diag = hypot(Double(width), Double(height))
            let (px, py) = predict(t)
            let gate = max(2.5 * old.diameter, diag * max(0.035, 2.5 * dt))
            let continuation = max(1.5 * old.diameter, 0.01 * diag + 0.35 * hypot(vx, vy) * min(dt, 0.1))
            var continuous: [(Double, ROICandidate)] = [], jumps: [(Double, ROICandidate)] = []
            for d in valid {
                guard (0.25...4).contains(d.width / old.width),
                      (0.25...4).contains(d.height / old.height) else { continue }
                let residual = hypot(d.x - px, d.y - py)
                let distance = min(residual, hypot(d.x - old.x, d.y - old.y))
                guard distance <= gate else { continue }
                let cost = (smallMode ? residual : distance) / gate
                    + 0.15 * abs(log(sqrt(d.width * d.height / (old.width * old.height))))
                    - (smallMode ? 0.5 : 0.1) * d.score
                if !smallMode || residual <= continuation { continuous.append((cost, d)) }
                else if d.score >= 0.25 { jumps.append((cost, d)) }
            }
            func best(_ list: [(Double, ROICandidate)]) -> ROICandidate? {
                list.min { a, b in a.0 == b.0 ? a.1.score > b.1.score : a.0 < b.0 }?.1
            }
            if let d = best(continuous) { selected = d; clearSwitch() }
            else if smallMode, let d = best(jumps) {
                if switchConfirmed(d, t) { forget(); selected = d; switched = true }
                else { reason = "awaiting_switch_confirmation" }
            } else { clearSwitch() }
        } else {
            selected = valid.max { $0.score < $1.score }; clearSwitch()
        }
        guard let d = selected else { misses += 1; trustedHits = 0; return (nil, reason) }
        if let old = last {
            let dt = t - lastSeen
            var x = (d.x - old.x) / dt, y = (d.y - old.y) / dt
            let speed = hypot(x, y), maximum = 4 * hypot(Double(width), Double(height))
            if speed > maximum { x *= maximum / speed; y *= maximum / speed }
            vx = 0.7 * x + 0.3 * vx; vy = 0.7 * y + 0.3 * vy
        }
        if d.score >= 0.25 {
            lastStrong = t; trustedHits += 1; confirmed = confirmed || trustedHits >= 2
        } else { trustedHits = 0 }
        last = d; lastSeen = t; misses = 0
        sizes.append((t, d.diameter / Double(max(width, height))))
        return (d, switched ? "reacquired_after_confirmation" : (confirmed ? "associated" : "acquiring"))
    }
}
