#if DEBUG
import CoreGraphics
import Foundation

nonisolated struct WallFourInRow: Equatable {
    struct Drop: Equatable {
        let cell: Int
        let player: WallPartyPlayer
        let time: Double
    }
    static let handover = 1.0
    static let board = CGRect(x: 0.17, y: 0.28, width: 2.66, height: 1.56)
    static func centre(_ cell: Int) -> CGPoint {
        CGPoint(x: board.minX + (Double((cell - 1) % 7) + 0.5) * board.width / 7,
                y: board.minY + (Double((cell - 1) / 7) + 0.5) * board.height / 6)
    }
    static let lines: [[Int]] = {
        var result: [[Int]] = []
        for row in 0..<6 {
            for col in 0..<7 {
                for (dx, dy) in [(1, 0), (0, 1), (1, 1), (-1, 1)] {
                    guard (0..<7).contains(col + 3 * dx), (0..<6).contains(row + 3 * dy) else { continue }
                    result.append((0..<4).map { (row + $0 * dy) * 7 + col + $0 * dx + 1 })
                }
            }
        }
        return result
    }()
    private(set) var cells: [Int: WallPartyPlayer] = [:]
    private(set) var player = WallPartyPlayer.one
    private(set) var readyAt = 0.0
    private(set) var finished = false
    private(set) var winner: WallPartyPlayer?
    private(set) var winningLine: [Int] = []
    private(set) var drops: [Drop] = []
    private(set) var events: [WallArcadeEvent] = []
    private var lastContact = -Double.infinity

    @discardableResult
    mutating func hit(point: CGPoint, contact: Double, now: Double) -> Int? {
        guard !finished, contact.isFinite, now.isFinite, contact <= now,
              contact >= readyAt, contact > lastContact,
              let column = WallTargetLayout.fourColumns.target(u: point.x, v: point.y) else { return nil }
        lastContact = contact
        guard let row = (0..<6).reversed().first(where: { cells[$0 * 7 + column] == nil }) else {
            events.append(.init(id: events.count, kind: "column_full", time: now, contactTime: contact,
                                target: column, point: point, cue: .memoryMiss, player: player.rawValue))
            return nil
        }
        let cell = row * 7 + column
        cells[cell] = player
        drops.append(.init(cell: cell, player: player, time: now))
        events.append(.init(id: events.count, kind: "chip_dropped", time: now, contactTime: contact,
                            target: column, point: point, cue: .tileClaim, player: player.rawValue))
        if let line = Self.lines.first(where: { $0.allSatisfy { cells[$0] == player } }) {
            winningLine = line; winner = player; finished = true
        } else if cells.count == 42 { finished = true }
        if finished {
            events.append(.init(id: events.count, kind: winner == nil ? "match_draw" : "match_won",
                                time: now, cue: .victory, player: winner?.rawValue))
        } else { player = player.other; readyAt = now + Self.handover }
        return cell
    }
}

/// Rules and drawing share these vertices, including the empty gaps between hexes.
nonisolated struct WallTerritoryDuel: Equatable {
    struct Zone: Identifiable, Equatable {
        let id: Int
        let centre: CGPoint
        var vertices: [CGPoint] {
            (0..<6).map { i in
                let angle = Double(i) * .pi / 3
                return CGPoint(x: centre.x + 0.29 * cos(angle), y: centre.y + 0.34 * sin(angle))
            }
        }
        func contains(_ p: CGPoint) -> Bool {
            guard p.x.isFinite, p.y.isFinite else { return false }
            let v = vertices
            return (0..<6).allSatisfy { i in
                let a = v[i], b = v[(i + 1) % 6]
                return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -1e-10
            }
        }
    }
    static let zones: [Zone] = {
        var result: [Zone] = []
        for col in 0..<5 {
            let count = col.isMultiple(of: 2) ? 3 : 2
            for row in 0..<count {
                result.append(.init(id: result.count + 1,
                    centre: CGPoint(x: 0.59 + Double(col) * 0.455,
                                    y: (count == 3 ? 0.36 : 0.68) + Double(row) * 0.64)))
            }
        }
        return result
    }()
    static let shotsPerPlayer = 10
    static let shotSeconds = 20.0, handover = 2.5, confirmationGrace = 0.8
    private(set) var owners: [Int: WallPartyPlayer] = [:]
    private(set) var player = WallPartyPlayer.one
    private(set) var readyAt = 0.0
    private(set) var shots = 0
    private(set) var events: [WallArcadeEvent] = []
    private var lastContact = -Double.infinity
    var finished: Bool { shots == Self.shotsPerPlayer * 2 }
    var deadline: Double { readyAt + Self.shotSeconds }
    var shotNumber: Int { min(Self.shotsPerPlayer, shots / 2 + 1) }
    func score(_ player: WallPartyPlayer) -> Int { owners.values.filter { $0 == player }.count }
    var winner: WallPartyPlayer? {
        guard finished, score(.one) != score(.two) else { return nil }
        return score(.one) > score(.two) ? .one : .two
    }
    mutating func advance(at time: Double) {
        guard time.isFinite, !finished, time > deadline + Self.confirmationGrace else { return }
        resolve(point: nil, contact: nil, now: time)
    }
    @discardableResult
    mutating func hit(point: CGPoint, contact: Double, now: Double) -> Int? {
        guard contact.isFinite, now.isFinite, contact <= now, WallTargetLayout.territoryField.contains(point) else { return nil }
        advance(at: now)
        guard !finished, contact >= readyAt, contact <= deadline, contact > lastContact else { return nil }
        lastContact = contact
        resolve(point: point, contact: contact, now: now)
        return shots
    }
    private mutating func resolve(point: CGPoint?, contact: Double?, now: Double) {
        let zone = point.flatMap { p in Self.zones.first { $0.contains(p) } }
        let previous = zone.flatMap { owners[$0.id] }
        let kind = point == nil ? "turn_timeout" : zone == nil ? "zone_missed"
            : previous == player ? "zone_already_owned" : previous == nil ? "zone_claimed" : "zone_stolen"
        if let zone { owners[zone.id] = player }
        events.append(.init(id: events.count, kind: kind, time: now, contactTime: contact,
            target: zone?.id, point: point, cue: zone != nil && previous != player ? .tileClaim : .memoryMiss,
            player: player.rawValue))
        shots += 1
        if finished {
            events.append(.init(id: events.count, kind: winner == nil ? "match_draw" : "match_won",
                time: now, cue: .victory, player: winner?.rawValue))
        } else { player = player.other; readyAt = now + Self.handover }
    }
}

nonisolated struct WallCopyMyShot: Equatable {
    struct Challenge: Equatable {
        let setter: WallPartyPlayer
        let target: CGPoint?
        let reply: CGPoint?
        let distance: Double?
        let matched: Bool
        let winner: WallPartyPlayer
        let time: Double
        var json: [String: Any] {
            ["setter": setter.rawValue, "target": target.map { [$0.x, $0.y] } as Any? ?? NSNull(),
             "reply": reply.map { [$0.x, $0.y] } as Any? ?? NSNull(),
             "distanceBoardUnits": distance as Any? ?? NSNull(), "radiusBoardUnits": WallCopyMyShot.radius,
             "matched": matched, "winner": winner.rawValue, "activeTime": time]
        }
    }
    static let challengeCount = 6
    static let shotSeconds = 20.0, handover = 2.5, confirmationGrace = 0.8
    // Board-space tolerance, not an unmeasured physical distance in centimetres.
    static let radius = 0.25
    static let settingArea = CGRect(x: 0.33, y: 0.33, width: 2.34, height: 1.34)
    private(set) var challenges: [Challenge] = []
    private(set) var target: CGPoint?
    private(set) var readyAt = 0.0
    private(set) var events: [WallArcadeEvent] = []
    private var lastContact = -Double.infinity
    var finished: Bool { challenges.count == Self.challengeCount }
    var setter: WallPartyPlayer { challenges.count.isMultiple(of: 2) ? .one : .two }
    var player: WallPartyPlayer { target == nil ? setter : setter.other }
    var deadline: Double { readyAt + Self.shotSeconds }
    var challengeNumber: Int { min(Self.challengeCount, challenges.count + 1) }
    func score(_ player: WallPartyPlayer) -> Int { challenges.filter { $0.winner == player }.count }
    var winner: WallPartyPlayer? {
        guard finished, score(.one) != score(.two) else { return nil }
        return score(.one) > score(.two) ? .one : .two
    }
    mutating func advance(at time: Double) {
        guard time.isFinite, !finished, time > deadline + Self.confirmationGrace else { return }
        complete(reply: nil, contact: nil, now: time)
    }
    @discardableResult
    mutating func hit(point: CGPoint, contact: Double, now: Double) -> Int? {
        guard contact.isFinite, now.isFinite, contact <= now, WallTargetLayout.copyField.contains(point) else { return nil }
        advance(at: now)
        guard !finished, contact >= readyAt, contact <= deadline, contact > lastContact else { return nil }
        lastContact = contact
        if target == nil {
            guard Self.settingArea.contains(point) else {
                events.append(.init(id: events.count, kind: "set_outside_area", time: now, contactTime: contact,
                    point: point, cue: .memoryMiss, player: player.rawValue))
                return nil
            }
            events.append(.init(id: events.count, kind: "shot_set", time: now, contactTime: contact,
                point: point, cue: .tileClaim, player: player.rawValue))
            target = point; readyAt = now + Self.handover
        } else { complete(reply: point, contact: contact, now: now) }
        return events.count
    }
    private mutating func complete(reply: CGPoint?, contact: Double?, now: Double) {
        let distance = target.flatMap { a in reply.map { Double(hypot($0.x - a.x, $0.y - a.y)) } }
        let matched = distance.map { $0 <= Self.radius + 1e-10 } ?? false
        let awarded = target == nil || matched ? setter.other : setter
        let kind = target == nil ? "setter_timeout" : reply == nil ? "reply_timeout" : matched ? "shot_matched" : "shot_missed"
        challenges.append(.init(setter: setter, target: target, reply: reply, distance: distance,
                                matched: matched, winner: awarded, time: now))
        events.append(.init(id: events.count, kind: kind, time: now, contactTime: contact,
            point: reply, cue: matched ? .goal : .memoryMiss, player: awarded.rawValue))
        target = nil
        if finished {
            events.append(.init(id: events.count, kind: winner == nil ? "match_draw" : "match_won",
                time: now, cue: .victory, player: winner?.rawValue))
        } else { readyAt = now + Self.handover }
    }
}
#endif
