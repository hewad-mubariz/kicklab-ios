import Foundation

/// A timestamped identity decision, not a predicted pose. Small enough to keep
/// in numeric traces; all-person boxes are kept only in the current UI snapshot.
nonisolated struct ActivePlayerSelection: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case searching, locked, obscured, ambiguous }
    let state: State
    let id: Int?
    let box: PersonBox?
    let observed: Bool
    let peopleCount: Int

    var canMatchPose: Bool { id != nil && box != nil && (state == .locked || state == .obscured) }
}

/// One active player. Association uses measured boxes and elapsed time; ball
/// proximity acquires a player but cannot steal an established lock mid-flight.
/// Ambiguous crossings suspend association instead of guessing an identity.
nonisolated struct ActiveJugglerTracker {
    static let signature = "|active-juggler-v1"
    struct Player: Equatable, Sendable { let id: Int; let box: PersonBox }
    private struct Track {
        let id: Int
        var box: PersonBox
        var lastSeen: Int
    }
    private var tracks: [Track] = []
    private var active: Int?
    private var nextID = 1
    private var lastTime: Int?
    private var acquiring: Int?
    private var acquiringSince = 0
    private var acquiringViews = 0
    private(set) var players: [Player] = []

    mutating func reset() { self = Self() }

    mutating func update(people: [PersonBox], ball: BallObservation?, timestampMs: Int) -> ActivePlayerSelection {
        if let lastTime, timestampMs <= lastTime || timestampMs-lastTime > 1500 {
            // Keep IDs unique across discontinuities so buffered evidence cannot
            // accidentally join a player from before a camera/clock interruption.
            tracks = []; active = nil; acquiring = nil
        }
        lastTime = timestampMs
        tracks.removeAll { timestampMs-$0.lastSeen > 1200 }
        if let active, !tracks.contains(where: { $0.id == active }) { self.active = nil }
        let boxes = Array(people.filter { $0.isUsable }.prefix(8))
        var matched: [Int: Int] = [:], used: Set<Int> = [], contested: Set<Int> = []
        // Mutual, unambiguous best matches. Detector query order/confidence is
        // deliberately not an identity signal.
        for index in tracks.indices {
            let scores = boxes.indices.map { ($0, Self.affinity(tracks[index].box, boxes[$0])) }
                .sorted { $0.1 > $1.1 }
            guard let best = scores.first, best.1 >= 0.42 else { continue }
            let rivals = tracks.indices.filter { $0 != index }.map { Self.affinity(tracks[$0].box, boxes[best.0]) }
            guard (scores.count == 1 || best.1-scores[1].1 >= 0.10),
                  best.1-(rivals.max() ?? 0) >= 0.10, !used.contains(best.0) else {
                contested.insert(index); continue
            }
            matched[index] = best.0; used.insert(best.0)
        }
        var visible: [Player] = []
        for (index, boxIndex) in matched {
            tracks[index].box = boxes[boxIndex]; tracks[index].lastSeen = timestampMs
            visible.append(.init(id: tracks[index].id, box: boxes[boxIndex]))
        }
        for index in boxes.indices where !used.contains(index) {
            // Do not mint duplicate identities inside an unresolved crossing.
            guard !tracks.indices.contains(where: { contested.contains($0) && Self.affinity(tracks[$0].box, boxes[index]) >= 0.42 }),
                  tracks.count < 8 else { continue }
            let track = Track(id: nextID, box: boxes[index], lastSeen: timestampMs)
            nextID += 1; tracks.append(track)
            visible.append(.init(id: track.id, box: track.box))
        }
        players = boxes.enumerated().map { index, box in
            // Negative display-only IDs show unresolved people in grey. They
            // never enter association, acquisition or contact evidence.
            visible.first(where: { $0.box == box }) ?? .init(id: -(index+1), box: box)
        }
        if let active, let index = tracks.firstIndex(where: { $0.id == active }) {
            let track = tracks[index], observed = visible.contains { $0.id == active }
            let ambiguous = contested.contains(index)
            return .init(state: observed ? .locked : ambiguous ? .ambiguous : .obscured,
                id: active, box: observed || (!ambiguous && timestampMs-track.lastSeen <= 500) ? track.box : nil,
                observed: observed, peopleCount: boxes.count)
        }
        let ranked = visible.map { ($0, Self.interaction($0.box, ball: ball)) }.sorted { $0.1 > $1.1 }
        if let best = ranked.first, best.1 >= 0.55,
           ranked.count == 1 || best.1-ranked[1].1 >= 0.18 {
            if acquiring != best.0.id { acquiring = best.0.id; acquiringSince = timestampMs; acquiringViews = 0 }
            acquiringViews += 1
            // Preserve immediate single-player startup. With spectators require
            // repeated compatible observations for at least 300 ms.
            if boxes.count == 1 || (timestampMs-acquiringSince >= 300 && acquiringViews >= 4) {
                active = best.0.id
                return .init(state: .locked, id: active, box: best.0.box, observed: true, peopleCount: boxes.count)
            }
        } else { acquiring = nil; acquiringViews = 0 }
        return .init(state: boxes.count > 1 ? .ambiguous : .searching, id: nil, box: nil, observed: false, peopleCount: boxes.count)
    }

    static func affinity(_ a: PersonBox, _ b: PersonBox) -> Double {
        let scale = min(a.width/b.width, b.width/a.width) * min(a.height/b.height, b.height/a.height)
        let distance = hypot((a.x-b.x)/max(a.width,b.width), (a.y-b.y)/max(a.height,b.height))
        guard scale >= 0.25, distance < 0.85 else { return 0 }
        return 0.65*a.iou(b) + 0.25*max(0,1-distance) + 0.10*scale
    }

    private static func interaction(_ box: PersonBox, ball: BallObservation?) -> Double {
        guard let ball else { return 0 }
        // Contact-compatible horizontal corridor, allowing lifted/outside feet.
        // A ball high above several people cannot identify its owner.
        let dx = max(0,abs(ball.x-box.x)-box.width*0.5)/box.width
        let dy = max(0,abs(ball.y-box.y)-box.height*0.5)/box.height
        guard dx <= 0.5, dy <= 0.25 else { return 0 }
        return max(0,1-dx*1.2-dy*2-abs(ball.x-box.x)/box.width*0.25)
    }
}

nonisolated extension PersonBox {
    var isUsable: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    func iou(_ other: Self) -> Double {
        let w = max(0,min(x+width/2,other.x+other.width/2)-max(x-width/2,other.x-other.width/2))
        let h = max(0,min(bottom,other.bottom)-max(y-height/2,other.y-other.height/2))
        let intersection = w*h
        return intersection/max(0.000001,width*height+other.width*other.height-intersection)
    }
}
