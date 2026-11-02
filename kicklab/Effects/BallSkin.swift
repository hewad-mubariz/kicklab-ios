import Foundation

nonisolated enum BallSkin: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Preserve the previous raw IDs so existing selections still resolve.
    case original, classic, stealth, matrix, gold, arctic, crimson, galaxy, chrome, graffiti, aurora
    case metal, lava, pearl, volt
    /// Accepted in the Effects Lab on 1 November 2026 and drawn by its shaders.
    case goldPolish, prism, wave, nightPulse
    var id: String { rawValue }
    /// Every ball picker's order, newest first after Original. Each skin appears once.
    static let pickerOrder: [BallSkin] = [.original, .goldPolish, .prism, .wave, .nightPulse,
                                          .metal, .lava, .pearl, .volt, .chrome, .arctic, .matrix,
                                          .stealth, .crimson, .gold, .galaxy, .graffiti, .aurora, .classic]
    /// Lab skins are lit shaders rather than artwork maps; LabSkinRenderer draws them.
    var isLabSkin: Bool { self == .goldPolish || self == .prism || self == .wave || self == .nightPulse }
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
        case .goldPolish: return "Gold Polish"
        case .prism: return "Prism"
        case .wave: return "Wave"
        case .nightPulse: return "Night Pulse"
        }
    }
    var materialResource: String { "ball-skin-" + rawValue }
}
