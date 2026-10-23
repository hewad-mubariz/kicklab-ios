import AVFoundation
import Foundation

/// For now a submission carries short clips of its flagged moments, not the whole
/// recording: each moment's window, cut from the recording and joined in order. The
/// operator review tool rebuilds the same windows to map the clips back to the recording.
nonisolated enum LeaderboardMomentClips {
    struct Window: Equatable, Sendable {
        var startMS: Int
        var endMS: Int
        var durationMS: Int { endMS - startMS }
    }

    struct Prepared: Sendable {
        let file: URL
        /// Exactly the moments the clips show. Fewer than recorded, and marked incomplete,
        /// when the clips had to be trimmed to fit the upload limit.
        let review: LeaderboardTouchReview?
    }

    private struct Saved: Codable {
        let proposal: RankedStreakProposal
        let review: LeaderboardTouchReview?
        /// The moments asked for, before any trimming.
        var requested: LeaderboardTouchReview? = nil
    }

    /// Windows in recording order, with overlapping or touching ones merged. With no flagged
    /// moments, the first and last seconds of the proposed streak stand in.
    static func windows(for moments: [LeaderboardReviewMoment], proposal: RankedStreakProposal,
                        durationMS: Int) -> [Window] {
        var raw = moments.map { Window(startMS: $0.clipStartMS, endMS: $0.clipEndMS) }
        if raw.isEmpty {
            raw = [Window(startMS: proposal.startMS - 1_000, endMS: proposal.startMS + 1_200),
                   Window(startMS: proposal.endMS - 1_200, endMS: proposal.endMS + 1_000)]
        }
        var clamped: [Window] = []
        for window in raw {
            let start = min(max(0, window.startMS), durationMS)
            let end = min(max(0, window.endMS), durationMS)
            if end > start { clamped.append(Window(startMS: start, endMS: end)) }
        }
        clamped.sort { $0.startMS == $1.startMS ? $0.endMS < $1.endMS : $0.startMS < $1.startMS }
        var merged: [Window] = []
        for window in clamped {
            if let last = merged.last, window.startMS <= last.endMS {
                merged[merged.count - 1].endMS = max(last.endMS, window.endMS)
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    /// The order moments earn a place when the clips must be trimmed: those inside the
    /// proposed streak first, then those that split a streak, then by time.
    static func prioritized(_ moments: [LeaderboardReviewMoment],
                            proposal: RankedStreakProposal) -> [LeaderboardReviewMoment] {
        func inside(_ moment: LeaderboardReviewMoment) -> Bool {
            moment.lastTimeMS >= proposal.startMS && moment.timeMS <= proposal.endMS
        }
        return moments.sorted { a, b in
            if inside(a) != inside(b) { return inside(a) }
            if a.kind.breaksStreak != b.kind.breaksStreak { return a.kind.breaksStreak }
            return a.timeMS < b.timeMS
        }
    }

    /// Builds the clip file for a submission, or reuses the one an earlier try made, so a
    /// resumed upload sends the very same bytes the attempt was registered with.
    static func prepare(source: URL, review: LeaderboardTouchReview?, proposal: RankedStreakProposal,
                        durationMS: Int, folder: URL, session: UUID, limit: Int64) async throws -> Prepared {
        let file = folder.appendingPathComponent(session.uuidString + ".moments.mov")
        let manifest = folder.appendingPathComponent(session.uuidString + ".moments.json")
        if FileManager.default.fileExists(atPath: file.path),
           let data = try? Data(contentsOf: manifest),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.proposal == proposal,
           (saved.requested ?? review) == review || saved.review == review {
            return Prepared(file: file, review: saved.review)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var included = review
        var windows = windows(for: review?.moments ?? [], proposal: proposal, durationMS: durationMS)
        try await export(source: source, windows: windows, to: file)
        var size = bytes(file)
        if size > limit, let review, !review.moments.isEmpty {
            // Too many moments for one upload: keep the ones that matter most to this streak.
            // Each clip starts at a keyframe, so short clips cost more than their share of
            // bytes; tighten the budget until the cut fits.
            let shown = Double(max(1, windows.reduce(0) { $0 + $1.durationMS }))
            var budgetMS = Double(limit) * 0.9 / (Double(size) / shown)
            for _ in 0..<5 where size > limit {
                var kept: [LeaderboardReviewMoment] = []
                for moment in prioritized(review.moments, proposal: proposal) {
                    let trial = kept + [moment]
                    let length = Self.windows(for: trial, proposal: proposal, durationMS: durationMS)
                        .reduce(0) { $0 + $1.durationMS }
                    if Double(length) <= budgetMS { kept = trial }
                }
                kept.sort { $0.timeMS < $1.timeMS }
                included = LeaderboardTouchReview(version: review.version, durationMS: review.durationMS,
                                                  complete: false, moments: kept)
                windows = Self.windows(for: kept, proposal: proposal, durationMS: durationMS)
                try await export(source: source, windows: windows, to: file)
                size = bytes(file)
                budgetMS *= 0.9 * Double(limit) / Double(max(size, 1))
            }
        }
        guard size <= limit else {
            try? FileManager.default.removeItem(at: file)
            throw LeaderboardFailure.tooLarge
        }
        try JSONEncoder().encode(Saved(proposal: proposal, review: included, requested: review))
            .write(to: manifest, options: [.atomic, .completeFileProtection])
        return Prepared(file: file, review: included)
    }

    /// Drops a submission's clip file once it has been sent or abandoned.
    static func remove(folder: URL, session: UUID) {
        for suffix in [".moments.mov", ".moments.json"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(session.uuidString + suffix))
        }
    }

    /// Cuts the windows from the recording into one file, without re-encoding.
    static func export(source: URL, windows: [Window], to destination: URL) async throws {
        do {
            try await cut(source: source, windows: windows, to: destination)
        } catch let failure as LeaderboardFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LeaderboardFailure.clips
        }
    }

    private static func cut(source: URL, windows: [Window], to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LeaderboardFailure.originalRequired
        }
        let available = try await track.load(.timeRange)
        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LeaderboardFailure.upload
        }
        output.preferredTransform = try await track.load(.preferredTransform)
        var cursor = CMTime.zero
        for window in windows {
            let wanted = CMTimeRange(start: CMTime(value: Int64(window.startMS), timescale: 1000),
                                     end: CMTime(value: Int64(window.endMS), timescale: 1000))
            // A recording's file can end a few milliseconds before the session's duration.
            let range = wanted.intersection(available)
            guard range.duration > .zero else { continue }
            try output.insertTimeRange(range, of: track, at: cursor)
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw LeaderboardFailure.originalRequired }
        try? FileManager.default.removeItem(at: destination)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw LeaderboardFailure.upload
        }
        try await session.export(to: destination, as: .mov)
    }

    /// Read fresh each time: a URL caches its resource values, and the clip file is rewritten in place.
    private static func bytes(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
