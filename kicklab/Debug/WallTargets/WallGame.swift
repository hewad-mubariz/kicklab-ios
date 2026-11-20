#if DEBUG
import CoreGraphics
import Foundation

/// Geometry is in continuous board coordinates (0...3, 0...2), independent of
/// ball calibration. The renderer and contact detector use the same targets.
nonisolated struct WallTargetLayout: Equatable, Sendable {
    struct Target: Identifiable, Equatable, Sendable {
        let id: Int
        let frame: CGRect
        let health: Int
        /// The brick shader leaves a 2.5% clear margin around its stone face.
        let faceInset: Double
        var hitFrame: CGRect { frame.insetBy(dx: frame.width * faceInset, dy: frame.height * faceInset) }
        func screenFrame(in board: CGRect) -> CGRect {
            CGRect(x: board.minX + frame.minX / 3 * board.width, y: board.minY + frame.minY / 2 * board.height,
                   width: frame.width / 3 * board.width, height: frame.height / 2 * board.height)
        }
    }
    let id: String
    let targets: [Target]
    var continuousSurface = false

    func contains(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...3).contains(point.x) && (0...2).contains(point.y)
    }
    var ids: [Int] { targets.map(\.id) }
    func target(_ id: Int) -> Target? { targets.first { $0.id == id } }
    func target(u: Double, v: Double) -> Int? {
        guard u.isFinite, v.isFinite else { return nil }
        return targets.first {
            let r = $0.hitFrame
            return u >= r.minX && v >= r.minY && (u < r.maxX || u == 3 && r.maxX == 3)
                && (v < r.maxY || v == 2 && r.maxY == 2)
        }?.id
    }
    static let sixTargets = WallTargetLayout(id: "static-six-zones-v1", targets: (1...6).map {
        Target(id: $0, frame: CGRect(x: Double(($0 - 1) % 3), y: Double(($0 - 1) / 3), width: 1, height: 1),
               health: 1, faceInset: 0)
    })
    static let legacyBricks = WallTargetLayout(id: "static-six-zones-v1", targets: sixTargets.targets.map {
        Target(id: $0.id, frame: $0.frame, health: $0.id <= 3 ? 2 : 1, faceInset: 0)
    })
    static let memoryPads = WallTargetLayout(id: "memory-four-symbols-v2", targets: (1...4).map {
        Target(id: $0, frame: CGRect(x: 0.38 + Double(($0 - 1) % 2) * 1.20,
            y: 0.37 + Double(($0 - 1) / 2) * 0.80, width: 1.04, height: 0.68), health: 1, faceInset: 0.04)
    })
    static let meteorField = WallTargetLayout(id: "meteor-continuous-field-v1", targets: [], continuousSurface: true)
    static let crossCircle = WallTargetLayout(id: "cross-circle-nine-v1", targets: (1...9).map {
        Target(id: $0, frame: CGRect(x: 0.48 + Double(($0 - 1) % 3) * 0.70,
            y: 0.13 + Double(($0 - 1) / 3) * 0.60, width: 0.64, height: 0.54),
               health: 1, faceInset: 0)
    })
    static let goalField = WallTargetLayout(id: "goal-duel-continuous-v1", targets: [], continuousSurface: true)
    static let fourColumns = WallTargetLayout(id: "four-in-row-columns-v1", targets: (1...7).map {
        Target(id: $0, frame: CGRect(x: 0.17 + Double($0 - 1) * 0.38, y: 0.06, width: 0.38, height: 1.80), health: 1, faceInset: 0)
    }, continuousSurface: true)
    static let territoryField = WallTargetLayout(id: "territory-hex-field-v1", targets: [], continuousSurface: true)
    static let copyField = WallTargetLayout(id: "copy-shot-continuous-v1", targets: [], continuousSurface: true)
    // A dense, stepped wall: contacts belong to the continuous surface, while
    // these bricks are material that can be damaged by the same impact.
    static let brickWall: WallTargetLayout = {
        let counts = [3, 5, 7, 6, 5, 4]
        // Half-brick offsets break up vertical seams; asymmetric row ends keep
        // the silhouette closer to a built wall than a centred stack of tiles.
        let starts = [0.871, 0.667, 0.055, 0.259, 0.463, 0.667]
        var targets: [Target] = []
        for (row, count) in counts.enumerated() {
            for column in 0..<count {
                let step = Double((row * 3 + column * 2) % 5) * 0.002
                targets.append(Target(id: targets.count + 1,
                    frame: CGRect(x: starts[row] + Double(column) * 0.408,
                                  y: 0.10 + Double(row) * 0.23 + step,
                                  width: 0.4, height: 0.218 - step),
                    health: 2, faceInset: 0.025))
            }
        }
        return WallTargetLayout(id: "blast-wall-30-v5", targets: targets, continuousSurface: true)
    }()
}

nonisolated enum WallGame: String, CaseIterable, Identifiable, Sendable {
    case clearTheWall = "clear-the-wall-v1"
    case brickBlast = "brick-blast-v1"
    case memoryStrike = "memory-strike-v1"
    case meteorDefence = "meteor-defence-v1"
    case crossCircle = "cross-circle-v1"
    case goalDuel = "goal-duel-v1"

    case fourInRow = "four-in-row-v1"
    case territoryDuel = "territory-duel-v1"
    case copyMyShot = "copy-my-shot-v1"

    var id: String { rawValue }
    var isParty: Bool { [.crossCircle, .goalDuel, .fourInRow, .territoryDuel, .copyMyShot].contains(self) }
    var isArcade: Bool { self == .memoryStrike || self == .meteorDefence || isParty }
    var layout: WallTargetLayout {
        switch self {
        case .clearTheWall: .sixTargets
        case .brickBlast: .brickWall
        case .memoryStrike: .memoryPads
        case .meteorDefence: .meteorField
        case .crossCircle: .crossCircle
        case .goalDuel: .goalField
        case .fourInRow: .fourColumns
        case .territoryDuel: .territoryField
        case .copyMyShot: .copyField
        }
    }
    var targetIDs: [Int] { layout.ids }
    var targetCount: Int { layout.targets.count }
    var title: String {
        switch self {
        case .clearTheWall: "Clear the Wall"
        case .brickBlast: "Brick Blast"
        case .memoryStrike: "Memory Strike"
        case .meteorDefence: "Meteor Defence"
        case .crossCircle: "Cross & Circle"
        case .goalDuel: "Goal Duel"
        case .fourInRow: "Four in a Row"
        case .territoryDuel: "Territory Duel"
        case .copyMyShot: "Copy My Shot"
        }
    }
    var headline: String {
        switch self {
        case .clearTheWall: "CLEAR\nTHE WALL"
        case .brickBlast: "BRICK\nBLAST"
        case .memoryStrike: "MEMORY\nSTRIKE"
        case .meteorDefence: "METEOR\nDEFENCE"
        case .crossCircle: "CROSS &\nCIRCLE"
        case .goalDuel: "GOAL\nDUEL"
        case .fourInRow: "FOUR IN\nA ROW"
        case .territoryDuel: "TERRITORY\nDUEL"
        case .copyMyShot: "COPY\nMY SHOT"
        }
    }
    var subtitle: String {
        switch self {
        case .clearTheWall: "Six targets. Your fastest time."
        case .brickBlast: "Kick. Shatter. Bring it down."
        case .memoryStrike: "Watch. Remember. Kick it back."
        case .meteorDefence: "Aim skyward. Save the city."
        case .crossCircle: "Two players. Three in a row."
        case .goalDuel: "Beat the keeper. Beat your friend."
        case .fourInRow: "Pick a column. Connect four."
        case .territoryDuel: "Claim it. Steal it. Own the wall."
        case .copyMyShot: "Set the spot. Can they match it?"
        }
    }
    var instructions: String {
        switch self {
        case .clearTheWall: "Hit every target in any order. Gold means cleared."
        case .brickBlast: "Smash the wall. A hit can break several bricks and crack its neighbours."
        case .memoryStrike: "Watch the symbols light up. Kick them in the same order. Five rounds, three lives."
        case .meteorDefence: "Kick the falling meteors before they reach the city. Survive three waves with three shields."
        case .crossCircle: "Share one ball. X starts. Take turns kicking empty squares. First to three in a row wins."
        case .goalDuel: "Share one ball. Take turns: five shots each, 20 seconds per shot. Kick inside the goal and past the robot. Most goals wins."
        case .fourInRow: "Take turns. Hit any part of a column to drop your chip. Connect four across, up or diagonally. Full columns: try another."
        case .territoryDuel: "Ten shots each. Claim or steal a hex. Every shot counts, including misses and your own zones. Most zones wins. 20 seconds per turn."
        case .copyMyShot: "Set a spot inside the outline. Your rival must hit inside the gold ring to win the point; otherwise you score. Swap roles. Six challenges, 20 seconds per shot."
        }
    }
    var bestTimeKey: String {
        // Area destruction is a different challenge from the older target layouts.
        switch self {
        case .clearTheWall: "wallTargets.clearTheWall.bestActiveSeconds.v1"
        case .brickBlast: "wallTargets.brickBlast.blast30.bestActiveSeconds.v5"
        case .memoryStrike: "wallTargets.memoryStrike.bestActiveSeconds.v1"
        case .meteorDefence: "wallTargets.meteorDefence.bestActiveSeconds.v1"
        case .crossCircle: "wallTargets.crossCircle.bestActiveSeconds.v1"
        case .goalDuel: "wallTargets.goalDuel.bestActiveSeconds.v1"
        case .fourInRow: "wallTargets.fourInRow.bestActiveSeconds.v1"
        case .territoryDuel: "wallTargets.territoryDuel.bestActiveSeconds.v1"
        case .copyMyShot: "wallTargets.copyMyShot.bestActiveSeconds.v1"
        }
    }
    var bestScoreKey: String {
        self == .memoryStrike ? "wallTargets.memoryStrike.fourSymbols.bestScore.v2" : "wallTargets.\(rawValue).bestScore"
    }
    func initialHealth(for box: Int) -> Int { layout.target(box)?.health ?? 0 }
    var initialHealth: [Int] { layout.targets.map(\.health) }
}
#endif
