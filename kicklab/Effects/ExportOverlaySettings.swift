import CoreGraphics
import Foundation

nonisolated enum ExportBadgeStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case normal, particleBurst, fire, ice, lightning, galaxy, neonRing, ripple, flipboard, pixelBurst, goldenSparks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: "Normal"
        case .particleBurst: "Particle Burst"
        case .fire: "Fire"
        case .ice: "Ice"
        case .lightning: "Lightning"
        case .galaxy: "Galaxy"
        case .neonRing: "Neon Ring"
        case .ripple: "Ripple"
        case .flipboard: "Flipboard"
        case .pixelBurst: "Pixel Burst"
        case .goldenSparks: "Golden Sparks"
        }
    }
}

/// Coordinates are fractions of the available travel, inside the upright video.
/// This keeps the entire badge on-screen when its size or export quality changes.
nonisolated struct ExportOverlayPlacement: Codable, Equatable, Sendable {
    var x: Double = 0.5
    var y: Double = 0.04
    var scale: Double = 1
    /// Clockwise degrees in the upright video; part of the exported transform.
    var rotation: Double = 0

    init(x: Double = 0.5, y: Double = 0.04, scale: Double = 1, rotation: Double = 0) {
        self.x = x; self.y = y; self.scale = scale; self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey { case x, y, scale, rotation }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try values.decodeIfPresent(Double.self, forKey: .y) ?? 0.04
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        // Existing layouts keep their exact position and size, upright.
        rotation = try values.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }

    var radians: Double { Self.normalizedRotation(rotation) * .pi / 180 }
    static func normalizedRotation(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        var angle = value.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return angle
    }

    /// Unrotated rectangle, centered inside the rotated safe bounds.
    func rect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let margin = min(size.width, size.height) * 0.025
        let ratio: CGFloat = 180.0 / 240
        let factor = Self.clamp(scale, to: 0.5...1.75, fallback: 1)
        let c = abs(cos(radians)), s = abs(sin(radians))
        let width = min(min(size.width * 0.56, size.height * 0.36) * factor,
                        min((size.width - 2 * margin) / (c + ratio * s),
                            (size.height - 2 * margin) / (s + ratio * c)))
        let height = width * ratio
        let rotatedWidth = width * c + height * s, rotatedHeight = width * s + height * c
        return CGRect(x: margin + (rotatedWidth - width) / 2 + (size.width - 2 * margin - rotatedWidth) * Self.clamp(x, to: 0...1, fallback: 0.5),
                      y: margin + (rotatedHeight - height) / 2 + (size.height - 2 * margin - rotatedHeight) * Self.clamp(y, to: 0...1, fallback: 0.04),
                      width: width, height: height)
    }

    func rotatedBounds(in size: CGSize) -> CGRect {
        let frame = rect(in: size), c = abs(cos(radians)), s = abs(sin(radians))
        let width = frame.width * c + frame.height * s, height = frame.width * s + frame.height * c
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    func positioned(at center: CGPoint, in size: CGSize) -> Self {
        let frame = rotatedBounds(in: size)
        let margin = min(size.width, size.height) * 0.025
        var result = self
        result.x = Self.clamp((center.x - margin - frame.width / 2) / max(0.001, size.width - 2 * margin - frame.width), to: 0...1, fallback: 0.5)
        result.y = Self.clamp((center.y - margin - frame.height / 2) / max(0.001, size.height - 2 * margin - frame.height), to: 0...1, fallback: 0.5)
        return result
    }

    func translated(by delta: CGSize, in size: CGSize) -> Self {
        let frame = rect(in: size)
        return positioned(at: CGPoint(x: frame.midX + delta.width, y: frame.midY + delta.height), in: size)
    }

    /// Pinching and twisting keep the sticker's center fixed unless it hits an edge.
    func transformed(scale newScale: Double? = nil, rotation newRotation: Double? = nil, in size: CGSize) -> Self {
        let frame = rect(in: size)
        var result = self
        if let newScale { result.scale = Self.clamp(newScale, to: 0.5...1.75, fallback: 1) }
        if let newRotation { result.rotation = Self.normalizedRotation(newRotation) }
        return result.positioned(at: CGPoint(x: frame.midX, y: frame.midY), in: size)
    }

    func contains(_ point: CGPoint, in size: CGSize, padding: CGFloat = 0) -> Bool {
        let frame = rect(in: size), dx = point.x - frame.midX, dy = point.y - frame.midY
        let local = CGPoint(x: cos(radians) * dx + sin(radians) * dy, y: -sin(radians) * dx + cos(radians) * dy)
        return CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
            .insetBy(dx: -padding, dy: -padding).contains(local)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

nonisolated struct ExportOverlayItem: Codable, Equatable, Sendable {
    var enabled: Bool
    var style: ExportBadgeStyle
    var placement: ExportOverlayPlacement
}

nonisolated struct ExportOverlaySettings: Codable, Equatable, Sendable {
    var counter = ExportOverlayItem(enabled: true, style: .normal, placement: .init(x: 0.04, y: 0.08, scale: 0.65))
    var hasVisibleOverlays: Bool { counter.enabled }

    static func load() -> Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--session-design") { return Self() }
        #endif
        if let data = UserDefaults.standard.data(forKey: "kicklab.export.overlays.v1"),
           let saved = try? JSONDecoder().decode(Self.self, from: data) {
            // Decoding ignores the removed timer key; saving removes it permanently.
            saved.save()
            return saved
        }
        var initial = Self()
        if let previous = UserDefaults.standard.object(forKey: "kicklab.export.includeCounter") as? Bool {
            initial.counter.enabled = previous
        }
        return initial
    }

    func save() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--session-design") { return }
        #endif
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "kicklab.export.overlays.v1")
        }
    }
}

/// Playback controls only; this label is never drawn into the exported video.
nonisolated enum ExportPreviewTime {
    static func seconds(at time: Double) -> Int {
        Int(time.isFinite ? min(9_999_999, max(0, time)).rounded(.down) : 0)
    }
    static func label(at time: Double) -> String {
        let value = seconds(at: time)
        if value >= 3600 { return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
