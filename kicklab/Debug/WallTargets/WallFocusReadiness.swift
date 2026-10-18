#if DEBUG
import Foundation

/// Do not equate the initial `isAdjustingFocus == false` with a finished focus
/// operation. Allow it to start, then require fresh frames and a stable lens.
nonisolated struct WallFocusReadiness {
    let started: Double
    private var stableSince: Double?
    private var low = Double.infinity
    private var high = -Double.infinity
    private var lastSample: Double?

    init(started: Double) { self.started = started }

    mutating func observe(at time: Double, frameTime: Double?, adjusting: Bool, lens: Double) -> Bool {
        defer { lastSample = time }
        guard time - started >= 0.7, let frameTime, time - frameTime >= 0,
              time - frameTime <= 0.3, !adjusting, lens.isFinite,
              lastSample.map({ time - $0 <= 0.3 }) ?? true else {
            stableSince = nil; low = .infinity; high = -.infinity
            return false
        }
        low = min(low, lens); high = max(high, lens)
        if high - low > 0.004 { stableSince = nil; low = lens; high = lens }
        if stableSince == nil { stableSince = time }
        return time - stableSince! >= 0.4
    }
}
#endif
