import Foundation

/// Ask for current-pixel confirmation only when a marginal full-frame ball has
/// no recent spatially consistent strong anchor. Crops never seed this history.
nonisolated final class BallDetectionConfirmation {
    struct Request {
        let roi: [Int]
        let direct: [Double]
        let width: Int
        let height: Int
    }
    private var anchor: (time: Double, ball: [Double])?
    private var lastTime: Double?
    private var dimensions: [Int] = []

    func reset() { anchor = nil; lastTime = nil; dimensions = [] }

    func observe(time: Double?, width: Int, height: Int, direct: [Double]) -> Request? {
        guard min(width, height) > 0 else { reset(); return nil }
        if dimensions != [width, height] || time == nil || !(time?.isFinite ?? false)
            || (lastTime != nil && (time! <= lastTime! || time! - lastTime! > 0.15)) {
            reset()
        }
        dimensions = [width, height]
        lastTime = time?.isFinite == true ? time : nil
        if let anchor, let time, time - anchor.time > 0.15 { self.anchor = nil }
        guard MarginalBallRetry.valid(direct), direct[0] >= 0.30 else { return nil }
        let scale = Double(max(width, height)) / 1920
        if let anchor, MarginalBallRetry.distance(anchor.ball, direct, width, height)
            > max(32 * scale, 2 * max(anchor.ball[3] * Double(width), anchor.ball[4] * Double(height))) {
            self.anchor = nil
        }
        if direct[0] >= 0.45 {
            if let time, time.isFinite { anchor = (time, direct) }
            return nil
        }
        guard anchor == nil else { return nil }
        let diameter = max(direct[3] * Double(width), direct[4] * Double(height))
        let edge = min(width, height, max(Int(256 * scale), Int(ceil(1.6 * diameter))))
        let x = max(0, min(width - edge, Int((direct[1] * Double(width) - Double(edge) / 2).rounded())))
        let y = max(0, min(height - edge, Int((direct[2] * Double(height) - Double(edge) / 2).rounded())))
        return Request(roi: [x, y, edge, edge], direct: direct, width: width, height: height)
    }

    static func accepts(_ request: Request, crop: [Double], maskFill: Double) -> Bool {
        guard MarginalBallRetry.valid(crop), crop[0] >= 0.45,
              maskFill.isFinite, maskFill >= 0.15, maskFill <= 0.95 else { return false }
        let roi = request.roi
        let mapped = [crop[0],
            (Double(roi[0]) + crop[1] * Double(roi[2])) / Double(request.width),
            (Double(roi[1]) + crop[2] * Double(roi[3])) / Double(request.height),
            crop[3] * Double(roi[2]) / Double(request.width),
            crop[4] * Double(roi[3]) / Double(request.height)]
        let direct = request.direct
        let diameter = max(direct[3] * Double(request.width), direct[4] * Double(request.height))
        return MarginalBallRetry.distance(mapped, direct, request.width, request.height)
            <= max(12 * Double(max(request.width, request.height)) / 1920, diameter)
            && (3...4).allSatisfy { mapped[$0] / direct[$0] >= 0.5 && mapped[$0] / direct[$0] <= 2 }
    }
}
