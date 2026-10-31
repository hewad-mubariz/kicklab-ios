import Foundation

/// Measured amplitude evidence around a smoothed turn. Five or more consecutive visible observations must independently
/// resolve both sides of the same turn. All later contact vetoes still apply.
nonisolated enum ObservedFallAmplitude {
    struct Turn {
        let approach, contact, release: BallObservation
        var fall: Double { contact.y-approach.y }
        var rise: Double { contact.y-release.y }
        var impulse: Double {
            fall/Double(contact.timestampMs-approach.timestampMs)*1000
                + rise/Double(release.timestampMs-contact.timestampMs)*1000
        }
    }
    static func measure(_ input: [BallObservation], contactFrame: Int, through time: Int,
                        imageBottoms: [Int: Double] = [:]) -> Double? {
        turn(input, contactFrame: contactFrame, through: time, imageBottoms: imageBottoms)?.fall
    }

    static func turn(_ input: [BallObservation], contactFrame: Int, through time: Int,
                     imageBottoms: [Int: Double] = [:]) -> Turn? {
        guard let contact = input.first(where: { $0.frameIndex == contactFrame }) else { return nil }
        let views = input.filter {
            (-101...101).contains($0.timestampMs-contact.timestampMs) && $0.timestampMs <= time
        }.sorted { $0.timestampMs < $1.timestampMs }
        let before = views.filter { $0.timestampMs < contact.timestampMs }
        let after = views.filter { $0.timestampMs > contact.timestampMs }
        guard before.count >= 2, after.count >= 2,
              let approach = before.first, let release = after.last,
              contact.timestampMs-approach.timestampMs >= 65,
              release.timestampMs-contact.timestampMs >= 65,
              Set(views.map(\.frameIndex)).count == views.count,
              Set(views.map(\.timestampMs)).count == views.count,
              views.allSatisfy({ b in
                  let bottom = imageBottoms[b.frameIndex] ?? 1
                  return [b.x,b.y,b.width,b.height,b.confidence,bottom].allSatisfy(\.isFinite)
                    && b.width > 0 && b.height > 0 && (0.7...1).contains(b.confidence)
                    && b.x-b.width/2 >= 0 && b.x+b.width/2 <= 1
                    && b.y-b.height/2 >= bottom-1 && b.y+b.height/2 <= bottom
              }), zip(views,views.dropFirst()).allSatisfy({ a,b in
                  b.frameIndex == a.frameIndex+1 && (25...67).contains(b.timestampMs-a.timestampMs)
              }), views.map(\.width).max()! <= 1.25*views.map(\.width).min()!,
              views.map(\.height).max()! <= 1.25*views.map(\.height).min()!,
              views.allSatisfy({ $0.y <= contact.y }),
              zip(before,before.dropFirst()).allSatisfy({ $1.y >= $0.y-0.0035 }),
              zip(after,after.dropFirst()).allSatisfy({ $1.y <= $0.y+0.0035 }),
              contact.y-after[0].y >= 0.0035,
              contact.y-release.y >= 0.007 else { return nil }
        return Turn(approach: approach, contact: contact, release: release)
    }
}
