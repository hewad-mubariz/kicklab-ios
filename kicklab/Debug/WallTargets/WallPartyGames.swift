#if DEBUG
import CoreGraphics
import Foundation

nonisolated enum WallPartyPlayer: Int, CaseIterable {
    case one = 1, two
    var other: Self { self == .one ? .two : .one }
    var mark: String { self == .one ? "X" : "O" }
    var name: String { "PLAYER \(rawValue)" }
}

/// Turns belong to the displayed player, not to a detected person's identity.
/// The dead time between turns rejects rebounds and delayed prior-turn contacts.
nonisolated struct WallCrossCircle: Equatable {
    static let handover = 1.0
    static let lines = [[1,2,3], [4,5,6], [7,8,9], [1,4,7], [2,5,8], [3,6,9], [1,5,9], [3,5,7]]
    private(set) var cells: [Int: WallPartyPlayer] = [:]
    private(set) var player = WallPartyPlayer.one
    private(set) var readyAt = 0.0
    private(set) var finished = false
    private(set) var winner: WallPartyPlayer?
    private(set) var winningLine: [Int] = []
    private(set) var events: [WallArcadeEvent] = []
    private var lastContact = -Double.infinity

    @discardableResult
    mutating func hit(point: CGPoint, contact: Double, now: Double) -> Int? {
        guard !finished, contact.isFinite, now.isFinite, contact <= now,
              contact >= readyAt, contact > lastContact,
              let cell = WallTargetLayout.crossCircle.target(u: point.x, v: point.y) else { return nil }
        lastContact = contact
        guard cells[cell] == nil else {
            events.append(.init(id: events.count, kind: "occupied_cell", time: now,
                contactTime: contact, target: cell, point: point, cue: .memoryMiss, player: player.rawValue))
            return nil
        }
        cells[cell] = player
        events.append(.init(id: events.count, kind: "cell_claimed", time: now,
            contactTime: contact, target: cell, point: point, cue: .tileClaim, player: player.rawValue))
        if let line = Self.lines.first(where: { line in line.allSatisfy { cells[$0] == player } }) {
            finished = true; winner = player; winningLine = line
        } else if cells.count == 9 { finished = true }
        if finished {
            events.append(.init(id: events.count, kind: winner == nil ? "match_draw" : "match_won",
                time: now, cue: .victory, player: winner?.rawValue))
        } else {
            player = player.other
            readyAt = now + Self.handover
        }
        return cell
    }
}

nonisolated struct WallGoalDuel: Equatable {
    struct Shot: Equatable, Identifiable {
        enum Outcome: String { case goal, saved, wide, timeout }
        let id: Int
        let player: WallPartyPlayer
        let outcome: Outcome
        let point: CGPoint?
        let contact: Double?
        let time: Double
        let keeper: [KeeperPart]
        var json: [String: Any] {
            ["id": id, "player": player.rawValue, "outcome": outcome.rawValue,
             "point": point.map { [$0.x, $0.y] } as Any? ?? NSNull(),
             "contactActiveTime": contact as Any? ?? NSNull(), "activeTime": time,
             "keeperParts": keeper.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] }]
        }
    }
    struct KeeperPart: Equatable, Identifiable {
        let id: Int
        let frame: CGRect
    }
    static let shotsPerPlayer = 5
    static let shotSeconds = 20.0, handover = 3.0, confirmationGrace = 0.8
    static let opening = CGRect(x: 0.20, y: 0.24, width: 2.60, height: 1.48)
    private(set) var player = WallPartyPlayer.one
    private(set) var readyAt = 0.0
    private(set) var shots: [Shot] = []
    private(set) var events: [WallArcadeEvent] = []
    private(set) var finished = false
    private var lastContact = -Double.infinity
    var deadline: Double { readyAt + Self.shotSeconds }
    var shotNumber: Int { min(Self.shotsPerPlayer, shots.filter { $0.player == player }.count + 1) }
    func goals(_ player: WallPartyPlayer) -> Int { shots.filter { $0.player == player && $0.outcome == .goal }.count }
    var winner: WallPartyPlayer? {
        guard finished, goals(.one) != goals(.two) else { return nil }
        return goals(.one) > goals(.two) ? .one : .two
    }

    // Identical movement for both players' corresponding turns. This is also
    // used to render the robot: the face, body, arms, gloves and legs block shots.
    func keeper(at time: Double) -> [KeeperPart] {
        let age = max(0, time - readyAt)
        let x = 1.5 + 0.86 * sin(age * .pi / 3.6)
        let y = 1.02 + 0.07 * sin(age * .pi / 1.8)
        let rects = [
            CGRect(x: x - 0.12, y: y - 0.42, width: 0.24, height: 0.23),
            CGRect(x: x - 0.18, y: y - 0.17, width: 0.36, height: 0.40),
            CGRect(x: x - 0.37, y: y - 0.15, width: 0.18, height: 0.13),
            CGRect(x: x + 0.19, y: y - 0.15, width: 0.18, height: 0.13),
            CGRect(x: x - 0.48, y: y - 0.23, width: 0.14, height: 0.24),
            CGRect(x: x + 0.34, y: y - 0.23, width: 0.14, height: 0.24),
            CGRect(x: x - 0.16, y: y + 0.25, width: 0.13, height: 0.30),
            CGRect(x: x + 0.03, y: y + 0.25, width: 0.13, height: 0.30)
        ]
        return rects.enumerated().map { KeeperPart(id: $0.offset, frame: $0.element) }
    }

    mutating func advance(at time: Double) {
        guard time.isFinite, !finished else { return }
        if time > deadline + Self.confirmationGrace {
            resolve(.timeout, point: nil, contact: nil, at: time)
        }
    }

    @discardableResult
    mutating func hit(point: CGPoint, footprint: WallContactFootprint, contact: Double, now: Double) -> Shot? {
        guard now.isFinite, contact.isFinite, point.x.isFinite, point.y.isFinite,
              footprint.isValid, contact <= now else { return nil }
        advance(at: now)
        guard !finished, contact >= readyAt, contact <= deadline, contact > lastContact,
              WallTargetLayout.goalField.contains(point) else { return nil }
        lastContact = contact
        let radiusX = hypot(footprint.xAxis.x, footprint.yAxis.x)
        let radiusY = hypot(footprint.xAxis.y, footprint.yAxis.y)
        let ballBounds = CGRect(x: point.x - radiusX, y: point.y - radiusY,
                                width: radiusX * 2, height: radiusY * 2)
        let outcome: Shot.Outcome
        if !Self.opening.contains(ballBounds) { outcome = .wide }
        else if keeper(at: contact).contains(where: { Self.overlaps($0.frame, point: point, footprint: footprint) }) {
            outcome = .saved
        } else { outcome = .goal }
        resolve(outcome, point: point, contact: contact, at: now)
        return shots.last
    }

    /// Transform the robot rectangle into ball-ellipse space, then measure its
    /// edges against a unit circle. Avoids an oversized rectangular ball hitbox.
    static func overlaps(_ rect: CGRect, point: CGPoint, footprint: WallContactFootprint) -> Bool {
        guard footprint.isValid else { return false }
        if rect.contains(point) { return true }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map { p in
            let dx = p.x - point.x, dy = p.y - point.y
            return CGPoint(x: (dx * footprint.yAxis.y - dy * footprint.yAxis.x) / footprint.determinant,
                           y: (dy * footprint.xAxis.x - dx * footprint.xAxis.y) / footprint.determinant)
        }
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, -(a.x * dx + a.y * dy) / length)) : 0
            if hypot(a.x + t * dx, a.y + t * dy) <= 1 { return true }
        }
        return false
    }

    private mutating func resolve(_ outcome: Shot.Outcome, point: CGPoint?, contact: Double?, at now: Double) {
        let shot = Shot(id: shots.count + 1, player: player, outcome: outcome, point: point, contact: contact,
                        time: now, keeper: keeper(at: contact ?? now))
        shots.append(shot)
        events.append(.init(id: events.count, kind: "shot_" + outcome.rawValue, time: now,
            contactTime: contact, target: shot.id, point: point,
            cue: outcome == .goal ? .goal : .keeperSave, player: player.rawValue))
        finished = shots.count == Self.shotsPerPlayer * 2
        if finished {
            events.append(.init(id: events.count, kind: winner == nil ? "match_draw" : "match_won",
                time: now, cue: .victory, player: winner?.rawValue))
        } else {
            player = player.other
            readyAt = now + Self.handover
        }
    }
}
#endif
