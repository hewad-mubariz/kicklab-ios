#if DEBUG
import CoreGraphics

/// In-memory evidence only. Never restored from saved preferences or recordings.
/// Compare against the original hold, not successive reanchors, to prevent drift.
nonisolated struct WallSetupReuse: Equatable, Sendable {
    let corners: [CGPoint]
    let frameSize: CGSize

    func accepts(corners observed: [CGPoint], frameSize current: CGSize) -> Bool {
        guard current == frameSize, current.width > 0, current.height > 0,
              WallBoard.validCalibration(corners), WallBoard.validCalibration(observed) else { return false }
        return WallBoardAlignment.displacement(corners, observed, size: current)
            <= WallBoardAlignment.tolerancePixels
    }
}
#endif
