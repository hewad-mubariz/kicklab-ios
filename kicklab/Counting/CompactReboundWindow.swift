import Foundation

/// Candidate eligibility only. A continuous measured dip may need more than
/// two frames to separate; the counter must still prove a legal foot contact.
nonisolated enum CompactReboundWindow {
    struct Proposal { let approach, contact, release: BallObservation }
    static func proposal(in input: [BallObservation], at time: Int) -> Proposal? {
        let views = input.filter { (0...334).contains(time-$0.timestampMs) }
            .sorted { $0.timestampMs < $1.timestampMs }
        guard views.count >= 5, let release=views.last, release.timestampMs == time,
              Set(views.map(\.timestampMs)).count == views.count,
              Set(views.map(\.frameIndex)).count == views.count else { return nil }
        // Prefer the newest complete turn. A later candidate must not recover
        // a previous cycle once a new reversal has already happened.
        for index in (2..<(views.count-2)).reversed() {
            let contact=views[index]
            guard (65...167).contains(time-contact.timestampMs) else { continue }
            let before=views[..<index].filter { (25...101).contains(contact.timestampMs-$0.timestampMs) }
            let after=Array(views[(index+1)...])
            guard before.count >= 2, after.count >= 2, let approach=before.first,
                  contact.timestampMs-approach.timestampMs >= 65 else { continue }
            let window=before+[contact]+after
            guard window.allSatisfy({ b in
                [b.x,b.y,b.width,b.height,b.confidence].allSatisfy(\.isFinite)
                    && b.width > 0 && b.height > 0 && (0.7...1).contains(b.confidence)
                    && b.x-b.width/2 >= 0 && b.x+b.width/2 <= 1
                    && b.y-b.height/2 >= 0 && b.y+b.height/2 <= 1
            }), zip(window,window.dropFirst()).allSatisfy({ a,b in
                b.frameIndex == a.frameIndex+1 && (25...67).contains(b.timestampMs-a.timestampMs)
            }), window.map(\.height).max()! <= 1.25*window.map(\.height).min()!,
                window.map(\.width).max()! <= 1.25*window.map(\.width).min()!,
                zip(before,before.dropFirst()).allSatisfy({ $1.y >= $0.y-0.0035 }),
                contact.y >= before.last!.y,
                contact.y-approach.y >= max(0.007,0.1*contact.height),
                after.allSatisfy({ $0.y <= contact.y }),
                zip(after,after.dropFirst()).allSatisfy({ $1.y <= $0.y+0.0035 }),
                after.suffix(2).allSatisfy({ contact.y-$0.y >= max(0.0035,0.05*contact.height) }),
                contact.y-release.y >= max(0.007,0.15*contact.height),
                after[after.count-2].y-release.y >= 0.0035 else { continue }
            return .init(approach:approach,contact:contact,release:release)
        }
        return nil
    }
}
