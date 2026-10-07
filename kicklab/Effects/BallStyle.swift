//
//  BallStyle.swift
//  kicklab
//
//  Visual skins for the already-tracked ball. Detection and stats are untouched.
//

import CoreGraphics
import simd
import SwiftUI

/// Share-clip ball skins. v1 set matches the Effects picker.
nonisolated enum BallStyle: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case fire
    case ice
    case neon
    case galaxy
    case electric
    case aura
    case shadow
    case rainbow
    case pixel
    case nature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fire: return "Fire"
        case .ice: return "Ice"
        case .neon: return "Neon"
        case .galaxy: return "Galaxy"
        case .electric: return "Electric"
        case .aura: return "Aura"
        case .shadow: return "Shadow"
        case .rainbow: return "Rainbow"
        case .pixel: return "Pixel"
        case .nature: return "Nature"
        }
    }

    var assetName: String? {
        switch self {
        case .none: return "effect-card-none"
        case .fire: return "effect-card-fire"
        case .ice: return "effect-card-ice"
        case .neon: return "effect-card-neon"
        case .galaxy: return "effect-card-galaxy"
        case .electric: return "effect-card-electric"
        case .aura: return "effect-card-aura"
        case .shadow: return "effect-card-shadow"
        case .rainbow: return "effect-card-rainbow"
        case .pixel: return "effect-card-pixel"
        case .nature: return "effect-card-nature"
        }
    }

    @MainActor var tint: Color {
        switch self {
        case .none: return .white.opacity(0.45)
        case .fire: return Color(red: 1.0, green: 0.42, blue: 0.12)
        case .ice: return Color(red: 0.45, green: 0.85, blue: 1.0)
        case .neon: return Theme.brand
        case .galaxy: return Color(red: 0.72, green: 0.42, blue: 1.0)
        case .electric: return Color(red: 1, green: 0.82, blue: 0.18)
        case .aura: return Color(red: 0.87, green: 0.95, blue: 1)
        case .shadow: return Color(red: 0.53, green: 0.24, blue: 0.85)
        case .rainbow: return Color(red: 1, green: 0.44, blue: 0.7)
        case .pixel: return Color(red: 0.1, green: 0.85, blue: 1)
        case .nature: return Color(red: 0.43, green: 0.91, blue: 0.22)
        }
    }
}

/// How hard the skin draws — live stays instrument-quiet; replay sells the clip.
nonisolated enum BallStylePresentation: Sendable {
    case live
    case replay

    /// Caps user intensity so live never overpowers the counter HUD.
    func resolvedIntensity(_ user: Double) -> Double {
        switch self {
        case .live: return min(0.38, max(0, user) * 0.45)
        case .replay: return min(1, max(0, user))
        }
    }

    var trailSeconds: Double {
        switch self {
        case .live: return 0.45
        case .replay: return 0.95
        }
    }
}

/// Ball material is independent of the surrounding effect.
nonisolated enum BallSkin: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Preserve the previous raw IDs so existing selections still resolve.
    case original, classic, stealth, matrix, gold, arctic, crimson, galaxy, chrome, graffiti, aurora
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
        }
    }
    var materialResource: String { "ball-skin-" + rawValue }
}

nonisolated struct BallStyleSample: Sendable {
    /// Normalized, top-left coordinates in the UPRIGHT video, before preview cropping.
    var center: CGPoint
    var radius: CGFloat
    var boxSize: CGSize? = nil
    var confidence: Double
    var velocityY: Double?
    var time: Double = 0

    // The detector is calibrated at 0.05. Accepted low-score detections must not
    // make the material blink off; only genuinely missing tracks fade away.
    var visibility: Double { confidence >= 0.05 ? 1 : max(0, confidence / 0.05) }

    init(center: CGPoint, radius: CGFloat, confidence: Double, velocityY: Double? = nil) {
        self.center = center; self.radius = radius; self.confidence = confidence; self.velocityY = velocityY
    }

    init?(box: CGRect, confidence: Double, velocityY: Double? = nil) {
        guard box.width > 0, box.height > 0 else { return nil }
        center = CGPoint(x: box.midX, y: box.midY)
        radius = box.width / 2
        boxSize = box.size
        self.confidence = confidence; self.velocityY = velocityY
    }

    init(frame: RecordedFrame) {
        // Counter coordinates include motion compensation and smoothing lag.
        // Visuals must follow the actual ball in the recorded pixels instead.
        center = CGPoint(x: frame.x, y: frame.y)
        boxSize = CGSize(width: frame.width, height: frame.height)
        radius = frame.width / 2
        confidence = frame.detected ? frame.score : 0
        velocityY = frame.vy
        time = frame.time
    }

    func pixelRadius(in size: CGSize) -> CGFloat {
        guard let boxSize else { return radius * size.width }
        // A circle has different normalized width/height in a portrait frame.
        // The shorter physical axis also resists elongated motion-blur boxes.
        return min(boxSize.width * size.width, boxSize.height * size.height) / 2
    }
}

nonisolated struct SessionEditState: Hashable, Sendable {
    var style: BallStyle = .neon
    var intensity: Double = 0.7
    var ballSkin: BallSkin = .original
    var environment: EffectEnvironment = .original
    var scene: SceneSelection? = nil
    var isEdited: Bool { scene != nil || environment != .original || ballSkin != .original || (style != .none && intensity > 0.02) }
    var label: String {
        [scene?.environment.title,
         ballSkin != .original ? ballSkin.title : nil,
         style != .none && intensity > 0.02 ? "\(style.title) · \(Int((intensity * 100).rounded()))%" : nil,
         environment != .original ? environment.title : nil]
            .compactMap { $0 }.joined(separator: " + ")
    }
}

extension BallStyle {
    nonisolated var shaderID: Float {
        switch self {
        case .none: 0
        case .fire: 1
        case .ice: 2
        case .neon: 3
        case .galaxy: 4
        case .electric: 5
        case .aura: 6
        case .shadow: 7
        case .rainbow: 8
        case .pixel: 9
        case .nature: 10
        }
    }
    var caption: String {
        switch self {
        case .none: "Your original touch."
        case .fire: "Bring the heat."
        case .ice: "Stay cool."
        case .neon: "Bright trails. Bold energy."
        case .galaxy: "Out of this world."
        case .electric: "High energy. Maximum impact."
        case .aura: "Soft silver rings. Subtle glow."
        case .shadow: "Dark smoke. Mysterious energy."
        case .rainbow: "All the colors. Playful ribbons."
        case .pixel: "Digital trails. Pixel-perfect touches."
        case .nature: "Drifting leaves. Organic trails."
        }
    }
    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .fire: "flame.fill"
        case .ice: "snowflake"
        case .neon: "circle"
        case .galaxy: "sparkles"
        case .electric: "bolt.fill"
        case .aura: "circle.dotted.circle"
        case .shadow: "moon.fill"
        case .rainbow: "rainbow"
        case .pixel: "square.grid.2x2.fill"
        case .nature: "leaf.fill"
        }
    }
}

nonisolated enum EffectEnvironment: String, CaseIterable, Identifiable, Sendable {
    case original, night
    var id: String { rawValue }
    var title: String { self == .original ? "Original" : "Nightfall" }
    var caption: String { self == .original ? "Keep the natural light" : "Cool shadows. Brighter effects." }
    var shaderAmount: Float { self == .night ? 1 : 0 }
}
