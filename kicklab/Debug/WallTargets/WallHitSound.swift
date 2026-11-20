#if DEBUG
import Foundation

nonisolated enum WallHitSound: String, CaseIterable {
    case targetHit, targetClear, armourCrack, brickBreak, brickSmash, brickClear

    static func forHit(game: WallGame, remainingHealth: Int, cleared: Bool, brokenBricks: Int = 1) -> Self {
        guard game == .brickBlast else { return cleared ? .targetClear : .targetHit }
        return cleared ? .brickClear : remainingHealth > 0 ? .armourCrack : brokenBricks >= 3 ? .brickSmash : .brickBreak
    }

    var assets: [String] {
        switch self {
        case .armourCrack: (1...2).map { "wall-brick-crack-\($0)" }
        case .brickBreak: (1...3).map { "wall-brick-break-\($0)" }
        case .brickSmash: (1...3).map { "wall-brick-smash-\($0)" }
        case .brickClear: ["wall-brick-clear-1"]
        default: []
        }
    }
}
#endif
