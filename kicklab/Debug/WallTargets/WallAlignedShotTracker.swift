#if DEBUG
import CoreGraphics
import Foundation

/// Keeps measured trajectories across a bounded corner dropout. Contacts found
/// while obscured are held until the unchanged geometry is revalidated.
nonisolated struct WallAlignedShotTracker {
    private var detector: WallImpactDetector?
    private var epoch: Int?
    private var pending: [WallImpactDetector.Impact] = []
    private var decisions: [WallImpactDetector.Decision] = []

    mutating func reset() {
        detector = nil; epoch = nil; pending = []; decisions = []
    }

    func isAtWall(_ observation: WallImpactDetector.Observation) -> Bool {
        detector?.isAtWall(observation) ?? false
    }

    mutating func process(_ observation: WallImpactDetector.Observation?, at time: Double,
                         update: WallBoardAlignment.Update?, retainEvidence: Bool, canScore: Bool,
                         reference: WallBallReference?, size: CGSize, fps: Double) -> [WallImpactDetector.Impact] {
        guard retainEvidence, let update, let reference else { reset(); return [] }
        if epoch != update.evidenceEpoch {
            reset()
            let p = update.corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard p.count == 4, let board = WallBoard(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3]) else { return [] }
            detector = WallImpactDetector(board: board, reference: reference, imageWidth: size.width)
            detector?.rejectBorderline = true
            epoch = update.evidenceEpoch
        }
        detector?.processingFPS = fps
        if let observation { detector?.add(observation) }
        pending += detector?.impacts(now: time) ?? []
        decisions += (detector?.takeDecisions() ?? []).map { decision in
            var result = decision
            if !canScore, ["accepted", "borderline"].contains(result.reason) { result.reason = "alignment_pending" }
            return result
        }
        guard canScore else { return [] }
        let result = pending
        pending = []
        return result
    }

    mutating func takeDecisions() -> [WallImpactDetector.Decision] {
        defer { decisions = [] }
        return decisions
    }
}
#endif
