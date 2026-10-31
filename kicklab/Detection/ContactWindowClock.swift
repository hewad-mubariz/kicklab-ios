import Foundation

/// Bounded timing credit for contact-image work. A one-frame delivery variation
/// can borrow time from the next slot; it cannot increase the sustained rate.
nonisolated struct ContactWindowClock {
    static let signature = "|contact-window-clock-v1"
    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("--contact-window-clock-v1")
        #else
        return false
        #endif
    }
    let interval: Double = 0.3
    let credit: Double = 1.0 / 30.0
    private(set) var lastSource: Double?
    private(set) var nextWall: Double?

    mutating func admit(source: Double, now: Double, enforceWall: Bool = true) -> Bool {
        guard source.isFinite, now.isFinite,
              lastSource.map({ source - $0 >= interval - 0.000001 }) ?? true,
              !enforceWall || (nextWall.map({ now + credit >= $0 - 0.000001 }) ?? true) else { return false }
        lastSource = source
        nextWall = max(now, nextWall ?? now) + interval
        return true
    }
}
