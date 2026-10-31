import Foundation

// Diagnostic scheduling only. All modes retain the same RF model and evidence rules.
nonisolated enum RFCadenceMode: String, CaseIterable {
    case fixed12, fixed8, fixed6, thermal
}

/// Keep the existing wall-rate cap for regular detections, independently of
/// retries on older images. No source grid, reservation or catch-up is added.
/// Worker admission and each retry's own limits remain at their call sites.
nonisolated enum RFIndependentRegularClock {
    static let signature = "|rf-independent-regular-clock-v1"
    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("--rf-independent-regular-clock-v1")
            && !RFSourceCadence.enabled(arguments: arguments)
            && !arguments.contains("--rf-failed-retry-clock-v1")
        #else
        return false
        #endif
    }
    static func rateReady(now: Double, targetHz: Double, lastAny: Double,
                          lastRegular: Double, independent: Bool) -> Bool {
        RFSourceCadence.rateReady(version: 0, now: now, due: now, targetHz: targetHz,
            lastAny: independent ? lastRegular : lastAny, lastRegular: lastRegular)
    }
}

/// A completed retry that supplied no usable ball must not impose another
/// regular-rate wait. Restore only its own clock charge, never a newer job's.
nonisolated enum RFFailedRetryClock {
    static let signature = "|rf-failed-retry-clock-v1"
    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("--rf-failed-retry-clock-v1")
            && !RFSourceCadence.enabled(arguments: arguments)
            && !arguments.contains("--rf-independent-regular-clock-v1")
        #else
        return false
        #endif
    }
    static func restoredClock(current: Double, submitted: Double, previous: Double,
                              accepted: Bool) -> Double? {
        guard !accepted, [current,submitted,previous].allSatisfy(\.isFinite),
              current == submitted, previous < submitted else { return nil }
        return previous
    }
}

/// Opt-in scheduling experiment. Anchor regular detection opportunities to the
/// source clock. Busy/missed slots are skipped, never queued or caught up later.
/// Gap retries cannot shift this grid. The worker and wall-rate limits still apply.
nonisolated struct RFSourceCadence {
    static let signature = "|rf-source-cadence-v1"
    static let signatureV2 = "|rf-source-cadence-v2"
    static let signatureV3 = "|rf-source-cadence-v3"
    static let signatureV4 = "|rf-source-cadence-v4"
    static func version(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int {
        #if DEBUG
        if arguments.contains("--rf-source-cadence-v4") { return 4 }
        if arguments.contains("--rf-source-cadence-v3") { return 3 }
        if arguments.contains("--rf-source-cadence-v2") { return 2 }
        return arguments.contains("--rf-source-cadence-v1") ? 1 : 0
        #else
        return 0
        #endif
    }
    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        version(arguments: arguments) > 0
    }
    static func rateReady(version: Int, now: Double, due: Double, targetHz: Double,
                          lastAny: Double, lastRegular: Double) -> Bool {
        guard targetHz > 0 else { return false }
        return version >= 2
            ? now-lastRegular >= 0.5/targetHz && now-due <= 0.1
            : now-lastAny >= 1/targetHz
    }
    static func fitsDeadline(now: Double, due: Double, delay: Double, budget: Double) -> Bool {
        now.isFinite && due.isFinite && budget.isFinite && budget >= 0
            && now-due <= 0.1 && now+budget <= due+delay
    }
    private var anchor: Double?
    private var interval: Double?
    private var lastSlot: Int?
    private var lastSource: Double?
    private(set) var opportunities = 0
    private(set) var skippedSourceSlots = 0

    mutating func opportunity(source: Double, targetHz: Double, exactRate: Bool = false) -> Bool {
        guard source.isFinite, targetHz.isFinite, targetHz > 0,
              lastSource.map({ source > $0 }) ?? true else { return false }
        lastSource = source
        // The live engine admits at most 30 Hz. Its present 12 Hz wall interval
        // normally selects every third exposure (10 Hz). Preserve that budget
        // instead of accidentally increasing inference to twelve times/second.
        let period = exactRate ? 1/min(targetHz, 30) : ceil(30 / min(targetHz, 30)) / 30
        if anchor == nil || interval != period {
            anchor = source; interval = period; lastSlot = nil
        }
        let slot = Int(floor((source-anchor!+0.000001)/period))
        guard lastSlot.map({ slot > $0 }) ?? true else { return false }
        if let lastSlot { skippedSourceSlots += max(0, slot-lastSlot-1) }
        lastSlot = slot
        opportunities += 1
        return true
    }
}

nonisolated struct RFCadencePolicy {
    let mode: RFCadenceMode

    func targetHz(thermalState: Int) -> Double {
        // Critical/unknown thermal state must not start more inference.
        guard (0...2).contains(thermalState) else { return 0 }
        switch mode {
        case .fixed12: return 12
        case .fixed8: return 8
        case .fixed6: return 6
        case .thermal: return [12.0, 8.0, 6.0][thermalState]
        }
    }
}
