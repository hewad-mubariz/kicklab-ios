#if DEBUG
import CoreGraphics
import Foundation

/// Keeps measured trajectories across a bounded corner dropout. Contacts found
/// while obscured are held until the unchanged geometry is revalidated.
nonisolated struct WallAlignedShotTracker {
    private var detector: WallImpactDetector?
    private var epoch: Int?
    private var activeLayout: WallTargetLayout?
    private var pending: [WallImpactDetector.Impact] = []
    private var decisions: [WallImpactDetector.Decision] = []
    private(set) var contactPreview: WallImpactDetector.Impact?
    private var lastPreview = -Double.infinity

    mutating func reset() {
        detector = nil; epoch = nil; activeLayout = nil; pending = []; decisions = []
        contactPreview = nil; lastPreview = -Double.infinity
    }

    func isAtWall(_ observation: WallImpactDetector.Observation) -> Bool {
        detector?.isAtWall(observation) ?? false
    }

    mutating func process(_ observation: WallImpactDetector.Observation?, at time: Double,
                         update: WallBoardAlignment.Update?, retainEvidence: Bool, canScore: Bool,
                         reference: WallBallReference?, size: CGSize, fps: Double,
                         layout: WallTargetLayout = .sixTargets,
                         usesSparseDepthConsistency: Bool = false) -> [WallImpactDetector.Impact] {
        guard retainEvidence, let update, let reference else { reset(); return [] }
        if epoch != update.evidenceEpoch || activeLayout != layout {
            reset()
            let p = update.corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard p.count == 4, let board = WallBoard(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3]) else { return [] }
            detector = WallImpactDetector(board: board, reference: reference, imageWidth: size.width, layout: layout)
            detector?.rejectBorderline = true
            epoch = update.evidenceEpoch; activeLayout = layout
        }
        detector?.processingFPS = fps
        detector?.usesSparseDepthConsistency = usesSparseDepthConsistency
        if let observation { detector?.add(observation) }
        let previews = detector?.previewContacts(now: time) ?? []
        pending += detector?.impacts(now: time) ?? []
        if let preview = (previews + pending).last(where: {
            (layout.continuousSurface ? layout.contains(CGPoint(x: $0.u, y: $0.v)) : layout.target(u: $0.u, v: $0.v) != nil)
                && $0.t - lastPreview >= WallImpactDetector.minSeparation - 0.5 / max(fps, 1)
                && time - $0.t <= 1.6
        }) {
            contactPreview = preview
            lastPreview = preview.t
        }
        if let preview = contactPreview {
            let stillSupported = (previews + pending).contains {
                abs($0.t - preview.t) < WallImpactDetector.minSeparation
            }
            if time - preview.t > 1.6
                || (time - preview.t >= WallImpactDetector.settle && !stillSupported) {
                contactPreview = nil
            }
        }
        decisions += (detector?.takeDecisions() ?? []).map { decision in
            var result = decision
            if !canScore, ["accepted", "borderline"].contains(result.reason) { result.reason = "alignment_pending" }
            return result
        }
        guard canScore else { return [] }
        let result = pending
        pending = []
        if let preview = contactPreview,
           result.contains(where: { abs($0.t - preview.t) < WallImpactDetector.minSeparation }) {
            contactPreview = nil
        }
        return result
    }

    mutating func takeDecisions() -> [WallImpactDetector.Decision] {
        defer { decisions = [] }
        return decisions
    }
}
#endif
