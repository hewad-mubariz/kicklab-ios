import Foundation

nonisolated enum BallSkin: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Preserve the previous raw IDs so existing selections still resolve.
    case original, classic, stealth, matrix, gold, arctic, crimson, galaxy, chrome, graffiti, aurora
    case metal, lava, pearl, volt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .classic: return "Classic Pro"
        case .stealth: return "Stealth Matte"
        case .matrix: return "Neon Circuit"
        case .gold: return "Gold Elite"
        case .arctic: return "Arctic Ice"
        case .crimson: return "Crimson Pulse"
        case .galaxy: return "Galaxy"
        case .chrome: return "Chrome Pulse"
        case .graffiti: return "Street Graffiti"
        case .aurora: return "Aurora Gradient"
        case .metal: return "Metal"
        case .lava: return "Lava"
        case .pearl: return "Pearl"
        case .volt: return "Volt"
        }
    }
    var materialResource: String { "ball-skin-" + rawValue }
}
