import SwiftUI

/// Ways to show the juggle in the replay HUD. Each reads only measured data: ball height,
/// confirmed touches, completed bounces and the playhead.
nonisolated enum MotionStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case ballMotion, comet, bounceRun, heartbeat, melody, fireworks, skyMeter, combo, metronome, rainbowArcs
    var id: String { rawValue }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .ballMotion
    }

    var title: String {
        switch self {
        case .ballMotion: "Ball Motion"
        case .comet: "Comet"
        case .bounceRun: "Bounce Run"
        case .heartbeat: "Heartbeat"
        case .melody: "Melody"
        case .fireworks: "Fireworks"
        case .skyMeter: "Sky Meter"
        case .combo: "Combo"
        case .metronome: "Metronome"
        case .rainbowArcs: "Rainbow Arcs"
        }
    }

    var caption: String {
        switch self {
        case .ballMotion: "Original line graph"
        case .comet: "A fading trail follows the ball"
        case .bounceRun: "Hop pad to pad at your real height"
        case .heartbeat: "Every touch is a heartbeat"
        case .melody: "Each bounce is a note, pitched by height"
        case .fireworks: "Higher bounces, bigger fireworks"
        case .skyMeter: "Chase your best height"
        case .combo: "Steady touches build the multiplier"
        case .metronome: "Swings in time with your touches"
        case .rainbowArcs: "Every bounce, a band of color"
        }
    }

    var subtitle: String {
        switch self {
        case .ballMotion, .comet: "Vertical position"
        case .bounceRun: "Every touch, a new hop"
        case .heartbeat: "Touch rhythm"
        case .melody: "Bounce height as pitch"
        case .fireworks: "One burst per bounce"
        case .skyMeter: "Height against your best"
        case .combo: "Rhythm streak"
        case .metronome: "Tempo"
        case .rainbowArcs: "Height of each bounce"
        }
    }

    /// The small tag beside the header and under each picker card.
    var measure: String {
        switch self {
        case .ballMotion, .comet, .bounceRun, .skyMeter: "RELATIVE"
        case .heartbeat, .metronome: "TOUCHES / MIN"
        case .combo: "STREAK"
        case .melody, .fireworks, .rainbowArcs: "PER BOUNCE"
        }
    }

    var height: CGFloat {
        switch self {
        case .ballMotion: 62
        case .comet: 76
        case .heartbeat, .metronome: 80
        case .bounceRun, .melody, .combo: 88
        case .fireworks, .skyMeter, .rainbowArcs: 96
        }
    }
}

/// Illustrative picker thumbnails only. Replay always supplies the session's observations.
nonisolated enum MotionStyleSample {
    static let touches = (0...7).map { Double($0) * 0.8 }
    static let points: [CaptureMotionPoint] = (0...168).map { index in
        let time = Double(index) / 30
        let phase = (time / 0.8).truncatingRemainder(dividingBy: 1)
        let heights = [0.30, 0.42, 0.28, 0.50, 0.64, 0.48, 0.35, 0.42]
        let height = heights[min(7, Int(time / 0.8))]
        return CaptureMotionPoint(time: time, y: 0.86 - sin(phase * .pi) * height,
                                  x: 0.5 + 0.3 * sin(time * 2.3))
    }
    static let timeline = MotionStyleTimeline(points: points, touchTimes: touches)
    static let time = 4.45
    static let duration = 5.6

    static func preview(for style: MotionStyle) -> MotionStyleSnapshot {
        // Each thumbnail at a moment that shows its idea: a fresh burst, a landing, a full bar.
        switch style {
        case .fireworks: timeline.snapshot(at: 4.3, duration: duration)
        case .bounceRun: timeline.snapshot(at: 4.32, duration: duration)
        default: timeline.snapshot(at: time, duration: duration)
        }
    }
}
