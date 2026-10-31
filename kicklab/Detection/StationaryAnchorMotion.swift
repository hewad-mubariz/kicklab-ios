import Foundation

/// A starting spot is not background when four reliable detector observations
/// show sustained motion inside it. This only releases a tracking anchor;
/// person selection and every contact, hand, holding and ground check still run.
nonisolated enum StationaryAnchorMotion {
    struct Sample: Codable {
        let time: Double
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let score: Double
    }

    static func confirms(_ views: [Sample]) -> Bool {
        guard views.count == 4,
              views.allSatisfy({ view in
                  [view.time, view.x, view.y, view.width, view.height, view.score].allSatisfy(\.isFinite)
                    && view.width > 0 && view.height > 0 && view.score >= 0.8
              }) else { return false }
        let diameter = views.map { max($0.width, $0.height) }.max()!
        guard views.map(\.width).max()! <= 1.25 * views.map(\.width).min()!,
              views.map(\.height).max()! <= 1.25 * views.map(\.height).min()! else { return false }
        // Three independent movements exclude a single box jump or an isolated
        // bad exposure. Time is source time, never wall-clock request timing.
        for (before, after) in zip(views, views.dropFirst()) {
            let elapsed = after.time - before.time
            let distance = hypot(after.x - before.x, after.y - before.y) / diameter
            guard (0.025...0.15).contains(elapsed), (0.15...0.75).contains(distance) else { return false }
        }
        let spread = views.enumerated().flatMap { index, view in
            views.dropFirst(index + 1).map { hypot($0.x - view.x, $0.y - view.y) }
        }.max() ?? 0
        return spread >= 0.25 * diameter
    }
}
