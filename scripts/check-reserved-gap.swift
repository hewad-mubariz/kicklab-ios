import Foundation

@main struct ReservedGapContracts {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, line: UInt = #line) throws {
            guard value else { throw NSError(domain: "Reserved gap contract line \(line)", code: 1) }
            checks += 1
        }
        let r = ImpactGapReservation(index: 120, source: 4, due: 100, requestedAt: 100.21)
        func permits(_ now: Double = 100.24, index: Int = 120, source: Double = 4,
                     depth: Int = 1, budget: Double = 0.08) -> Bool {
            r.permits(index: index, source: source, now: now, outstanding: depth, budget: budget)
        }
        try check(permits())
        try check(!permits(index: 121))
        try check(!permits(source: 4.033))
        try check(!permits(100.261))
        try check(!permits(100.251)) // Existing backlog start deadline.
        try check(!permits(100.20))
        try check(!permits(depth: 5))
        try check(!permits(budget: 0.15))
        try check(!permits(budget: .nan))
        try check(!permits(.infinity))
        let translated = ImpactGapReservation(index: 120, source: 44, due: 200, requestedAt: 200.21)
        try check(translated.permits(index: 120, source: 44, now: 200.24, outstanding: 1, budget: 0.08))
        try check(!ImpactGapReservation.enabled(arguments: []))
        try check(!TrackingDrainBudget.enabled(arguments: []))
        #if DEBUG
        try check(ImpactGapReservation.enabled(arguments: ["--rf-reserved-gap-v1"]))
        try check(ImpactGapReservation.version(arguments: ["--rf-reserved-gap-v2"]) == 2)
        try check(ImpactGapReservation.version(arguments: ["--rf-reserved-gap-v3"]) == 3)
        try check(TrackingDrainBudget.enabled(arguments: ["--rf-drain-budget-v1"]))
        try check(!ImpactGapReservation.enabled(arguments: ["--rf-drain-budget-v1"]))
        #endif
        let shifted = ImpactGapReservation.regularClockAfterAdmission(version: 1, previous: 100, now: 100.033)
        let preserved = ImpactGapReservation.regularClockAfterAdmission(version: 2, previous: 100, now: 100.033)
        // The next 100 ms source exposure keeps its ordinary eligibility.
        try check(100.1-shifted < 1.0/12)
        try check(100.1-preserved >= 1.0/12)
        func drain(_ costs: [Double], version: Int) -> Int {
            var elapsed=0.0, count=0
            for cost in costs {
                guard ImpactGapReservation.continuesDrain(version: version, processed: count, elapsed: elapsed) else { break }
                elapsed += cost; count += 1
            }
            return count
        }
        // Saved burst: RF reseed + another seed + tracked exposures must not
        // occupy one ingestion call long enough to skip the next source frame.
        let burst=[0.0115,0.0215,0.0081,0.0075,0.0166,0.0061,0.0058]
        try check(drain(burst,version:2)==7)
        try check(drain(burst,version:3)==1)
        try check(drain([0.006,0.006,0.020],version:3)==2)
        try check(drain([0.030],version:3)==1)
        var schedule = ImpactGapRetrySchedule(chargesAcceptedOnly: false)
        var calls = 0
        let busy = schedule.attempt(source: 4, hintTime: 3.967, now: 100.21,
            due: 100, outstanding: 1, budget: 0.08, submit: { calls += 1; return false })
        try check(busy == .workerBusy && calls == 1)
        schedule.recordReservedAdmission(source: 4, now: 100.24)
        // The completed reservation owns the cooldown. Repeated busy polling
        // must not buy an extra job or shorten spacing from actual admission.
        let early = schedule.attempt(source: 4.31, hintTime: 4.277, now: 100.52,
            due: 100.31, outstanding: 1, budget: 0.08, submit: { calls += 1; return true })
        try check(early == .ineligible && calls == 1)
        let later = schedule.attempt(source: 4.34, hintTime: 4.307, now: 100.55,
            due: 100.34, outstanding: 1, budget: 0.08, submit: { calls += 1; return true })
        try check(later == .submitted && calls == 2)
        // Baseline semantics remain exactly the same when no reservation is made.
        var baseline = ImpactGapRetrySchedule(chargesAcceptedOnly: false)
        let sequence = [(0.0, false), (0.033, true), (0.334, true)].map { offset, idle in
            baseline.attempt(source: 10+offset, hintTime: 9.967+offset, now: 110.21+offset,
                due: 110+offset, outstanding: 1, budget: 0.08, submit: { idle })
        }
        try check(sequence == [.workerBusy, .ineligible, .submitted])
        print("PASS: \(checks) reserved-gap identity, deadline, backlog and rate contracts")
    }
}
