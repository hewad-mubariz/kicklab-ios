//
//  SessionSummary.swift
//  kicklab
//
//  Stats handed from a finished take into the post-recording flow.
//

import Foundation

struct SessionMilestone: Identifiable, Sendable, Hashable {
    let id: Int
    let threshold: Int
    let title: String

    static let catalog: [SessionMilestone] = [
        .init(id: 50, threshold: 50, title: "Keep going!"),
        .init(id: 100, threshold: 100, title: "Amazing!"),
        .init(id: 150, threshold: 150, title: "On fire!"),
        .init(id: 200, threshold: 200, title: "Legend!"),
    ]
}

struct SessionSummary: Sendable {
    let touches: Int
    let duration: TimeInterval
    let bestCombo: Int
    let maxHeightMeters: Double?
    let avgHeightMeters: Double?
    let personalBest: Int
    let videoURL: URL
    let touchesMarked: [RecordedTouch]
    let track: [RecordedFrame]
    let drops: Int
    let consistency: Double
    let touchTimeline: [Double]
    var sessionNumber: Int = 1
    var visualTrack: [RecordedFrame]? = nil
    /// Live frames remain the source of truth for stats. Precise replay masks are
    /// requested once, only by features which actually need them.
    var needsVisualPreparation = false
    var framesUseCompositionClock = false
    /// A position sidecar cannot be reused as precise replacement-mask evidence.
    var visualTrackIsPositionsOnly = false
    var debugContacts: [TouchDebugEvent] = []
    var leaderboardTouchReview: LeaderboardTouchReview? = nil
    var historyReplay: HistoryReplayContext? = nil
    var savedBestStreak: RankedStreakProposal? = nil
    var renderTrack: [RecordedFrame] { visualTrack ?? track }

    /// Imports without interruption evidence do not claim a continuous streak.
    var bestStreak: RankedStreakProposal? {
        guard duration.isFinite, duration > 0, duration <= 86400 else { return nil }
        if let saved = savedBestStreak, saved.count <= touches,
           saved.isValid(durationMS: Int((duration * 1000).rounded())) { return saved }
        guard let review = leaderboardTouchReview,
              var streak = RankedStreakProposal.suggest(touchTimes: touchesMarked.map(\.time),
                  boundaries: review.streakBoundaries, duration: duration) else { return nil }
        streak.count = min(streak.count, touches)
        return streak.count > 0 ? streak : nil
    }
    var bestStreakLabel: String { bestStreak.map { $0.count.formatted() } ?? "—" }
    var isNewBest: Bool { (bestStreak?.count ?? 0) > personalBest }

    var durationLabel: String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var maxHeightLabel: String {
        guard let maxHeightMeters else { return "—" }
        return String(format: "%.1f m", maxHeightMeters)
    }

    var avgHeightLabel: String {
        guard let avgHeightMeters else { return "—" }
        return String(format: "%.0f", avgHeightMeters * 100)
    }

    var consistencyPercent: Int {
        Int((consistency * 100).rounded())
    }

    var consistencyBlurb: String {
        switch consistencyPercent {
        case 90...: return "Great control! You kept a steady rhythm throughout."
        case 75..<90: return "Solid rhythm — a few wobbles, mostly locked in."
        case 50..<75: return "Getting there. Focus on even spacing between touches."
        default: return "Keep practicing — consistency climbs with every session."
        }
    }

    var milestonesReached: [SessionMilestone] {
        SessionMilestone.catalog.filter { touches >= $0.threshold }
    }

    var peakTouchesInWindow: Int {
        // Peak cumulative count visible on the timeline chart.
        Int(touchTimeline.map { $0 }.max() ?? Double(touches))
    }

    /// Build summary from the live HUD + recorded track.
    static func make(
        touches: Int,
        duration: TimeInterval,
        bestCombo: Int,
        personalBest: Int,
        videoURL: URL,
        touchesMarked: [RecordedTouch],
        track: [RecordedFrame],
        sessionNumber: Int = 1
    ) -> SessionSummary {
        let heights = track.compactMap { frame -> Double? in
            guard frame.detected else { return nil }
            return max(0.2, min(1.6, (1.0 - frame.smoothedY) * 1.4))
        }
        let maxH = heights.max()
        let avgH = heights.isEmpty ? nil : heights.reduce(0, +) / Double(heights.count)

        let timeline = Self.buildTimeline(touches: touchesMarked, duration: duration)
        let consistency = Self.consistencyScore(from: touchesMarked, duration: duration)

        return SessionSummary(
            touches: touches,
            duration: duration,
            bestCombo: max(0, min(bestCombo, touches)),
            maxHeightMeters: maxH,
            avgHeightMeters: avgH,
            personalBest: personalBest,
            videoURL: videoURL,
            touchesMarked: touchesMarked,
            track: track,
            drops: 0,
            consistency: consistency,
            touchTimeline: timeline, sessionNumber: sessionNumber
        )
    }

    /// Cumulative touches sampled across the session for the chart.
    private static func buildTimeline(touches: [RecordedTouch],
                                      duration: TimeInterval) -> [Double] {
        let buckets = 24
        let span = max(duration, touches.last?.time ?? 1, 0.1)
        var series = [Double](repeating: 0, count: buckets)
        for i in 0..<buckets {
            let t = span * Double(i + 1) / Double(buckets)
            series[i] = Double(touches.filter { $0.time <= t }.count)
        }
        if series.last == 0, !touches.isEmpty {
            series[buckets - 1] = Double(touches.count)
        }
        return series
    }

    /// How evenly spaced touches were (1 = metronome, 0 = chaotic / sparse).
    private static func consistencyScore(from touches: [RecordedTouch],
                                         duration: TimeInterval) -> Double {
        guard touches.count >= 3 else {
            return touches.isEmpty ? 0 : 0.55
        }
        let intervals = zip(touches, touches.dropFirst()).map { $1.time - $0.time }
            .filter { $0 > 0.05 && $0 < 3.0 }
        guard intervals.count >= 2 else { return 0.6 }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return 0.5 }
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
            / Double(intervals.count)
        let cv = sqrt(variance) / mean
        // Low coefficient of variation → high consistency.
        return max(0.35, min(0.98, 1.0 - cv * 0.85))
    }
}

enum JugglingRecords {
    static let bestKey = "kicklab.juggling.bestStreak"

    /// A legacy session total cannot be converted into a streak. Restore only
    /// recorded sessions that retained explicit streak data, once per install.
    static func migrateGuestBest(from sessions: [HistorySession], defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: bestKey) == nil else { return }
        restoreGuestBest(sessions.filter { $0.ownerID == nil }.map(\.personalBestStreak).max() ?? 0, defaults: defaults)
    }

    static var personalBest: Int {
        UserDefaults.standard.integer(forKey: bestKey)
    }

    static func recordIfNeeded(_ touches: Int, ownerID: UUID?, defaults: UserDefaults = .standard) {
        guard ownerID == nil, touches > defaults.integer(forKey: bestKey) else { return }
        defaults.set(touches, forKey: bestKey)
    }

    /// Older replays also wrote account scores into this device-only cache.
    /// Rebuild it from retained guest history after confirmed account deletion.
    static func restoreGuestBest(_ touches: Int, defaults: UserDefaults = .standard) {
        defaults.set(max(0, touches), forKey: bestKey)
    }
}

extension SessionSummary: Identifiable {
    var id: String { videoURL.absoluteString }
}
