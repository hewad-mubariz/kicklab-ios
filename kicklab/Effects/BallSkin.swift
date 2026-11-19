import Foundation

nonisolated enum BallSkin: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Preserve the previous raw IDs so existing selections still resolve.
    case original, classic, stealth, matrix, gold, arctic, crimson, galaxy, chrome, graffiti, aurora
    case metal, lava, pearl, volt
    /// Accepted in the Effects Lab on 1 November 2026 and drawn by its shaders.
    case goldPolish, prism, wave, nightPulse
    /// Effects Lab skins of November 2026, drawn through LabSkinBridge (test build).
    case kintsugi, porcelainTide, dragonhide, amberHive, turboCore, opalMosaic, crimsonVelvet, roseQuartz, coralBloom, meteorRelic, apexCarbon, redline, monoShift, ultraviolet, chromeArmor, plasmaCore, aeroWhite, scarletMesh, topoOrange, crownBlack, discoMirror, eightBall, puzzleSphere, gummyPop, airPop, toonBall, littleEarth, robotBuddy, treasureOrb, goalGlobe
    var id: String { rawValue }
    /// Every ball picker's order, newest first after Original. Each skin appears once.
    static let pickerOrder: [BallSkin] = [.original] + bridgedSkins + [.goldPolish, .prism, .wave, .nightPulse,
                                          .metal, .lava, .pearl, .volt, .chrome, .arctic, .matrix,
                                          .stealth, .crimson, .gold, .galaxy, .graffiti, .aurora, .classic]
    /// Lab skins are lit shaders rather than artwork maps; LabSkinRenderer draws them.
    var isLabSkin: Bool { self == .goldPolish || self == .prism || self == .wave || self == .nightPulse || isBridgedSkin }
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
        case .kintsugi: return "Kintsugi"
        case .porcelainTide: return "Porcelain Tide"
        case .dragonhide: return "Dragonhide"
        case .amberHive: return "Amber Hive"
        case .turboCore: return "Turbo Core"
        case .opalMosaic: return "Opal Mosaic"
        case .crimsonVelvet: return "Crimson Velvet"
        case .roseQuartz: return "Rose Quartz"
        case .coralBloom: return "Coral Bloom"
        case .meteorRelic: return "Meteor Relic"
        case .apexCarbon: return "Apex Carbon"
        case .redline: return "Redline"
        case .monoShift: return "Mono Shift"
        case .ultraviolet: return "Ultraviolet"
        case .chromeArmor: return "Chrome Armor"
        case .plasmaCore: return "Plasma Core"
        case .aeroWhite: return "Aero White"
        case .scarletMesh: return "Scarlet Mesh"
        case .topoOrange: return "Topo Orange"
        case .crownBlack: return "Crown Black"
        case .discoMirror: return "Disco Mirror"
        case .eightBall: return "Eight Ball"
        case .puzzleSphere: return "Puzzle Sphere"
        case .gummyPop: return "Gummy Pop"
        case .airPop: return "Air Pop"
        case .toonBall: return "Toon Ball"
        case .littleEarth: return "Little Earth"
        case .robotBuddy: return "Robot Buddy"
        case .treasureOrb: return "Treasure Orb"
        case .goalGlobe: return "Goal Globe"
        }
    }
    var materialResource: String { "ball-skin-" + rawValue }
}
