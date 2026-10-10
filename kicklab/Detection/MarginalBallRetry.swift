import Foundation

/// Fresh single-frame crop retry. Direct observations always win and recovered
/// observations never seed another retry. Reset explicitly at camera/clip changes.
nonisolated final class MarginalBallRetry {
    struct Request {
        let roi: [Int]
        let previous: [Double]
        let weak: [Double]
        let width: Int
        let height: Int
    }
    private var history: [(Double,[Double])] = []
    private var confirmedAt: Double?
    private var attemptedSinceDirect = false
    private var lastTime: Double?
    private var shape: [Int] = []
    func reset() { history = []; lastTime = nil; shape = []; confirmedAt = nil; attemptedSinceDirect = false }
    static func valid(_ b: [Double]) -> Bool {
        b.count == 5 && b.allSatisfy(\.isFinite) && b[0] > 0 && b[0] <= 1
            && b[1] >= 0 && b[1] <= 1 && b[2] >= 0 && b[2] <= 1
            && b[3] > 0 && b[3] <= 1 && b[4] > 0 && b[4] <= 1
    }
    static func distance(_ a: [Double], _ b: [Double], _ w: Int, _ h: Int) -> Double {
        hypot((a[1] - b[1]) * Double(w), (a[2] - b[2]) * Double(h))
    }
    func observe(time: Double, width: Int, height: Int,
                 direct: [Double], weak: [Double]) -> Request? {
        guard time.isFinite, min(width, height) > 0 else { reset(); return nil }
        if shape != [width, height] || lastTime == nil
            || time - lastTime! <= 0 || time - lastTime! > 0.10 { reset() }
        shape = [width, height]; lastTime = time
        history = history.filter { time - $0.0 <= 0.15 }
        let scale = Double(max(width, height)) / 1920
        if Self.valid(direct) && direct[0] >= 0.30 {
            if let prior = history.last?.1,
               Self.distance(prior, direct, width, height) > max(32 * scale,
                   2 * max(prior[3] * Double(width), prior[4] * Double(height))) {
                history = []; confirmedAt = nil
            }
            history.append((time,direct)); history = Array(history.suffix(64))
            attemptedSinceDirect = false
            if direct[0] >= 0.45 { confirmedAt = time }
            return nil
        }
        let old = history.filter { time - $0.0 <= 0.10 }.map { $0.1 }
        guard old.count >= 2, !attemptedSinceDirect, let confirmedAt, time - confirmedAt <= 0.15,
              Self.valid(weak), weak[0] >= 0.20, weak[0] < 0.30 else { return nil }
        let previous = old.last!
        let diameter = max(previous[3] * Double(width), previous[4] * Double(height))
        guard diameter <= 64 * scale,
              Self.distance(previous, weak, width, height) <= max(32 * scale, 2 * diameter),
              (3...4).allSatisfy({ weak[$0] / previous[$0] >= 0.5
                  && weak[$0] / previous[$0] <= 2 }) else { return nil }
        let edge = min(width, height, max(32, Int(256 * scale + 0.5)))
        let x = max(0, min(width-edge, Int(previous[1] * Double(width) - Double(edge)/2 + 0.5)))
        let y = max(0, min(height-edge, Int(previous[2] * Double(height) - Double(edge)/2 + 0.5)))
        attemptedSinceDirect = true
        return Request(roi: [x,y,edge,edge], previous: previous, weak: weak,
                       width: width, height: height)
    }
    static func accept(_ request: Request, crop: [Double], maskFill: Double) -> [Double]? {
        guard valid(crop), crop[0] >= 0.50, maskFill >= 0.15, maskFill <= 0.95 else { return nil }
        let x = Double(request.roi[0]), y = Double(request.roi[1])
        let w = Double(request.roi[2]), h = Double(request.roi[3])
        guard crop[1] - crop[3]/2 >= 2/w, crop[2] - crop[4]/2 >= 2/h,
              crop[1] + crop[3]/2 <= 1-2/w, crop[2] + crop[4]/2 <= 1-2/h else { return nil }
        let mapped = [crop[0], (x+crop[1]*w)/Double(request.width),
                      (y+crop[2]*h)/Double(request.height),
                      crop[3]*w/Double(request.width), crop[4]*h/Double(request.height)]
        let weak = request.weak
        let size = max(weak[3] * Double(request.width), weak[4] * Double(request.height))
        guard distance(mapped, weak, request.width, request.height) <= max(
            12 * Double(max(request.width, request.height))/1920, size),
              (3...4).allSatisfy({ mapped[$0]/weak[$0] >= 0.5 && mapped[$0]/weak[$0] <= 2 })
        else { return nil }
        return mapped
    }
}
