import Foundation

nonisolated struct LeaderboardReviewMoment: Codable, Equatable, Identifiable, Sendable {
    typealias Kind = ContactReviewReason
    let kind: Kind
    let timeMS: Int
    var lastTimeMS: Int
    let clipStartMS: Int
    var clipEndMS: Int
    var id: String { "\(kind.rawValue)-\(timeMS)" }
    var timestamp: String { String(format: "%d:%02d.%01d", timeMS / 60000, (timeMS / 1000) % 60, (timeMS % 1000) / 100) }
}

/// Untrusted device observations for a human reviewer, never an approved score.
nonisolated struct LeaderboardTouchReview: Codable, Equatable, Sendable {
    static let maximumMoments = 2_000
    let version: Int
    let durationMS: Int
    let complete: Bool
    let moments: [LeaderboardReviewMoment]

    var summary: String { moments.isEmpty ? String(localized: "No flagged moments") : String(localized: "\(moments.count) moments to review") }

    static func make(evidence: TouchReviewEvidence, touchTimes: [Double], duration: Double,
                     timeOrigin: Double = 0) -> Self? {
        guard duration.isFinite, duration > 0, duration <= 86_400, timeOrigin.isFinite else { return nil }
        let limit = max(1, Int((duration * 1000).rounded()))
        let times = Array(Set(touchTimes.filter { $0.isFinite && $0 >= 0 && $0 <= duration }
            .map { Int(($0 * 1000).rounded()) })).sorted()
        var observations = evidence.observations.compactMap { observation -> (Int, LeaderboardReviewMoment.Kind)? in
            let time = observation.time - timeOrigin
            guard time.isFinite, time >= 0, time <= duration else { return nil }
            return (Int((time * 1000).rounded()), observation.kind)
        }
        for (before, after) in zip(times, times.dropFirst()) where after - before > 2_000 {
            observations.append((before + min(1_000, (after - before) / 2), .continuityGap))
        }
        observations.sort { $0.0 == $1.0 ? $0.1.rawValue < $1.1.rawValue : $0.0 < $1.0 }
        var moments: [LeaderboardReviewMoment] = []
        var complete = evidence.complete
        for (time, kind) in observations {
            // Repeated reports of one incident are one card; a counted touch
            // between reports means they are different contacts.
            if var last = moments.last, last.kind == kind, time - last.lastTimeMS <= 350,
               time - last.timeMS <= 1_000,
               !hasTouch(in: times, after: last.lastTimeMS, through: time) {
                last.lastTimeMS = time; last.clipEndMS = min(limit, time + 1_200)
                moments[moments.count - 1] = last
            } else {
                guard moments.count < maximumMoments else { complete = false; break }
                moments.append(.init(kind: kind, timeMS: time, lastTimeMS: time,
                    clipStartMS: max(0, time - 1_000), clipEndMS: min(limit, time + 1_200)))
            }
        }
        return .init(version: 1, durationMS: limit, complete: complete, moments: moments)
    }

    var streakBoundaries: [Double] {
        moments.filter { $0.kind.breaksStreak }.flatMap { [Double($0.timeMS)/1000, Double($0.lastTimeMS)/1000] }
    }

    private static func hasTouch(in times: [Int], after start: Int, through end: Int) -> Bool {
        var low = 0, high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= start { low = middle + 1 } else { high = middle }
        }
        return low < times.count && times[low] <= end
    }
}

nonisolated extension ContactReviewReason {
    var breaksStreak: Bool { [.handContact, .heldBall, .groundContact].contains(self) }
    /// Why a streak ended, inside a sentence.
    var stopReason: String {
        switch self {
        case .heldBall: String(localized: "the ball was held")
        case .groundContact: String(localized: "the ball touched the ground")
        default: String(localized: "a hand or arm touched the ball")
        }
    }
    var title: String {
        switch self {
        case .handContact: String(localized: "Hand or arm contact detected")
        case .heldBall: String(localized: "Ball hold detected")
        case .groundContact: String(localized: "Ground contact detected")
        case .lowContactUncertain: String(localized: "Foot contact unclear")
        case .handsUncertain: String(localized: "Hand position unclear")
        case .bodyUncertain: String(localized: "Contact area unclear")
        case .playerUncertain: String(localized: "Player visibility unclear")
        case .ballUncertain: String(localized: "Ball tracking interrupted")
        case .continuityGap: String(localized: "Gap between counted touches")
        }
    }
    var explanation: String {
        switch self {
        case .handContact: String(localized: "The counter found hand or arm contact. This splits the suggested streak. If it was a valid touch, the original can be checked.")
        case .heldBall: String(localized: "The counter found a sustained hold. A catch or hold ends a streak. Review the footage if that looks wrong.")
        case .groundContact: String(localized: "The counter found evidence of a ground bounce. This splits the suggested streak; a reviewer can correct a mistaken detection.")
        case .lowContactUncertain: String(localized: "The ball was low, but the view did not clearly distinguish a foot touch from a ground bounce.")
        case .handsUncertain: String(localized: "The hands or arms were hidden or too close to the ball to verify the contact. This is not proof of a hand touch.")
        case .bodyUncertain: String(localized: "The counter could not confidently locate the body part making contact. The original may show a valid touch.")
        case .playerUncertain: String(localized: "The active player or contact area was not clear enough to verify this moment.")
        case .ballUncertain: String(localized: "The ball was missing or tracking was interrupted around this moment.")
        case .continuityGap: String(localized: "No touch was counted for more than two seconds. That alone does not prove a drop; the original needs checking.")
        }
    }
}
