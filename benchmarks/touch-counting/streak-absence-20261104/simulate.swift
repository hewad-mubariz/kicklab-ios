import Foundation
// Large simulation run outside Xcode, on the same rule code. Usage: sim <sessions per scenario>
let sessions = Int(CommandLine.arguments[1])!
for scenario in StreakScenario.allCases {
    var ended = 0, firstSeed: UInt64?, firstInfo = "", kinds: [String: Int] = [:]
    var worst: [String: Int] = [:]
    for i in 0..<sessions {
        let seed = UInt64(i)*7_919+UInt64(StreakScenario.allCases.firstIndex(of: scenario)!)
        var random = SeededGenerator(seed: seed)
        let gap = scenario.gap(using: &random)
        let result = gap.assess(using: &random)
        if !result.decisions.isEmpty {
            ended += 1
            for d in result.decisions { kinds[d.kind.rawValue, default: 0] += 1 }
            worst["\(gap.detector.repliesPerSecond) Hz ball \(gap.detector.ballRate)", default: 0] += 1
            if firstSeed == nil { firstSeed = seed; firstInfo = "\(gap.lengthMS) ms, \(gap.ballOut), \(gap.detector)" }
        }
    }
    print(scenario.rawValue, scenario.isValidStreak ? "VALID" : "STOP", "ended \(ended)/\(sessions)", kinds, scenario.isValidStreak && ended > 0 ? "first seed \(firstSeed!) \(firstInfo) \(worst.sorted { $0.value > $1.value }.prefix(6))" : (ended < sessions ? "missed \(sessions-ended)" : ""))
}

// Where does a valid streak start to break? Detection far below anything measured.
print("\nMARGIN: wrong breaks per 100,000 valid sessions, by replies per second and ball detection rate")
let hz: [Double] = [5, 7, 10, 15, 30], rates = [0.3, 0.4, 0.5, 0.6, 0.75, 0.87, 1]
for scenario in [StreakScenario.highKick, .twoHighKicksInARow, .ballHiddenByTheBody, .touchesMissedByTheCounter] {
    print(scenario.rawValue, "rates", rates)
    for h in hz {
        var row: [Int] = []
        for rate in rates {
            var ended = 0
            for i in 0..<(sessions/5) {
                var random = SeededGenerator(seed: UInt64(i)*104_729+UInt64(h*10)+UInt64(rate*1000)*65_537)
                var gap = scenario.gap(using: &random)
                gap.detector.repliesPerSecond = h; gap.detector.ballRate = rate; gap.detector.straysPerSecond = 0.6
                if !gap.assess(using: &random).decisions.isEmpty { ended += 1 }
            }
            row.append(ended*100_000/(sessions/5))
        }
        print("  \(h) Hz", row)
    }
}
