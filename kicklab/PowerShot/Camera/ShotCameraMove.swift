import CoreGraphics
import Foundation
import SwiftUI

/// Every camera move the Power Shot editor can place on its camera track. All of them work in
/// the picture (crops, timing, grading); none of them claims metres or speed.
nonisolated enum ShotCameraMove: String, CaseIterable, Identifiable, Codable, Sendable {
    // Follow: a virtual camera operator.
    case follow, chase, broadcast, handoff, split, duo
    // Hit: something happens on the strike.
    case impact, tilt, recoil, ripple, warp
    // Time: slow, hold or replay part of the shot.
    case ramp, freeze, arc, replay
    // Look: what you see changes, not where the camera points.
    case lens, spotlight, focus, strobe, lock

    var id: String { rawValue }

    enum Family: String, CaseIterable, Identifiable, Sendable {
        case follow = "Follow", hit = "Hit", time = "Time", look = "Look"
        var id: String { rawValue }
    }

    var family: Family {
        switch self {
        case .follow, .chase, .broadcast, .handoff, .split, .duo: .follow
        case .impact, .tilt, .recoil, .ripple, .warp: .hit
        case .ramp, .freeze, .arc, .replay: .time
        case .lens, .spotlight, .focus, .strobe, .lock: .look
        }
    }

    var title: String {
        switch self {
        case .follow: "Ball Follow"
        case .chase: "Chase Cam"
        case .broadcast: "Broadcast"
        case .handoff: "Handoff"
        case .split: "Wide + Detail"
        case .duo: "Duo Cam"
        case .impact: "Impact Zoom"
        case .tilt: "Tilt Punch"
        case .recoil: "Recoil"
        case .ripple: "Impact Ripple"
        case .warp: "Launch Warp"
        case .ramp: "Speed Ramp"
        case .freeze: "Freeze + Path"
        case .arc: "Frozen Arc"
        case .replay: "Instant Replay"
        case .lens: "Ball Lens"
        case .spotlight: "Spotlight"
        case .focus: "Rack Focus"
        case .strobe: "Ball Strobe"
        case .lock: "Target Lock"
        }
    }

    var symbol: String {
        switch self {
        case .follow: "scope"
        case .chase: "arrow.up.forward.circle"
        case .broadcast: "video.badge.waveform"
        case .handoff: "arrow.left.arrow.right"
        case .split: "rectangle.split.1x2"
        case .duo: "person.and.background.dotted"
        case .impact: "arrow.up.left.and.arrow.down.right"
        case .tilt: "rotate.left"
        case .recoil: "waveform.path"
        case .ripple: "dot.radiowaves.left.and.right"
        case .warp: "sparkles"
        case .ramp: "slowmo"
        case .freeze: "pause.rectangle"
        case .arc: "rotate.3d"
        case .replay: "arrow.counterclockwise.circle"
        case .lens: "magnifyingglass.circle"
        case .spotlight: "light.max"
        case .focus: "camera.aperture"
        case .strobe: "circle.grid.cross"
        case .lock: "viewfinder"
        }
    }

    var detail: String {
        switch self {
        case .follow: "A steady crop that leads the ball and zooms in as it flies away."
        case .chase: "Keeps the ball the same size on screen all the way to the goal."
        case .broadcast: "Moves like a TV camera operator: a little behind, a little overshoot."
        case .handoff: "Frames the kicker through the run-up, then whips to the ball."
        case .split: "The wide shot on top, a ball camera below."
        case .duo: "Splits on the strike: kicker on top, ball below."
        case .impact: "A punch-in that peaks on the contact frame."
        case .tilt: "A small tilt on the strike that settles back to level."
        case .recoil: "A harder hit: the frame kicks, overshoots and settles like a spring."
        case .ripple: "A refracting shockwave leaves the contact point."
        case .warp: "A short radial speed burst toward the ball at launch."
        case .ramp: "Slows part of the shot, easing in and out."
        case .freeze: "Holds a frame while the flight path draws itself on."
        case .arc: "Freezes on contact and swings the camera around the kicker, the goal sliding behind him."
        case .replay: "Rewinds the shot, then replays it in slow motion."
        case .lens: "A magnifier that follows the ball, tied to it by a line."
        case .spotlight: "Dims the scene except for a pool of light on the ball."
        case .focus: "Shallow focus that pulls from the foot to the flying ball."
        case .strobe: "Stamps the ball along its flight, like a long exposure."
        case .lock: "Brackets lock onto the ball and count the flight time."
        }
    }

    /// Track colour, by family, so a glance shows what kind of move sits where.
    @MainActor var tint: Color {
        switch family {
        case .follow: Color(red: 0.34, green: 0.96, blue: 0.65)
        case .hit: Color(red: 1, green: 0.62, blue: 0.27)
        case .time: Color(red: 0.42, green: 0.71, blue: 1)
        case .look: Color(red: 0.8, green: 0.56, blue: 1)
        }
    }

    /// Changes playback timing, so the saved video differs in length.
    var retimes: Bool { self == .ramp || self == .freeze || self == .arc || self == .replay }
    var needsBall: Bool { ![.tilt, .recoil].contains(self) }
    var needsPerson: Bool { self == .handoff || self == .duo }
    /// Hits are moments: they sit around the strike and are short.
    var isMoment: Bool { family == .hit }

    /// Where a fresh block goes, in source seconds, before it is fitted between neighbours.
    func defaultRange(strike: Double, flightEnd: Double, playhead: Double, duration: Double) -> ClosedRange<Double> {
        let end = max(strike + 0.4, flightEnd)
        // A little after the landing, so the camera can ease back to the original once the ball is down.
        let settle = end + 0.45
        let r: ClosedRange<Double>
        switch self {
        case .impact, .ripple: r = (strike - 0.12)...(strike + 0.5)
        case .tilt, .recoil: r = (strike - 0.06)...(strike + 0.5)
        case .warp: r = (strike - 0.03)...(strike + 0.6)
        case .ramp: r = (strike - 0.14)...(strike + 0.34)
        case .freeze: r = strike...settle
        case .arc: r = strike...(strike + 0.3)
        case .replay: r = (strike - 0.2)...end
        case .handoff, .duo: r = max(0, strike - 0.9)...settle
        case .follow, .chase, .broadcast, .split, .lens, .spotlight, .focus, .strobe, .lock:
            r = (strike - 0.3)...settle
        }
        let lo = min(max(0, r.lowerBound), max(0, duration - ShotCameraTrack.minimumLength))
        return lo...min(duration, max(lo + ShotCameraTrack.minimumLength, r.upperBound))
    }
}

/// Per-block settings. Each move reads the few it needs; the inspector shows only those.
nonisolated struct ShotMoveSettings: Equatable, Codable, Sendable {
    /// Zoom cap or magnification.
    var zoom = 2.0
    /// How strong the hit, blur, light or shake is (0.5 – 1.5).
    var strength = 1.0
    /// Slow-motion rate for Speed Ramp and Instant Replay.
    var rate = 0.33
    /// How long Freeze holds, in seconds.
    var hold = 1.1
    /// Tilt angle in degrees.
    var angle = 2.5
    /// A move's either/or: tilt right, stacked split, punchy impact, tight follow.
    var alternate = false
    /// Ease in and out (Speed Ramp), or keep the path after the freeze (Freeze + Path).
    var smooth = true
    /// A fixed point to look at instead of the ball, in the upright picture (0 – 1).
    var target: ShotCameraPoint?
    /// How the block hands back to the original picture when no neighbouring move takes over.
    var ending = Ending.ease
    /// Slow motion made of new in-between frames (where the device can make them), not repeats.
    var smoothMotion = true

    enum Ending: String, Codable, Sendable {
        /// The move winds down over the block's last moments and lands exactly on the original.
        case ease
        /// A hard cut back to the original on the block's last frame.
        case cut
    }

    /// How long an easing ending takes: up to half a second, never more than 40% of the block.
    static func release(length: Double) -> Double { min(0.5, max(0.2, length * 0.4)) }

    static func defaults(for move: ShotCameraMove) -> ShotMoveSettings {
        var s = ShotMoveSettings()
        switch move {
        case .follow: s.zoom = 2.4
        case .chase: s.zoom = 3.4
        case .broadcast: s.zoom = 2.4
        case .handoff: s.zoom = 2.4
        case .split: s.zoom = 2.8; s.alternate = true
        case .duo: s.zoom = 2.6
        case .impact: s.zoom = 2.1
        case .tilt: s.angle = 2.5; s.zoom = 1.1
        case .recoil: s.angle = 3
        case .ramp: s.rate = 0.25
        case .replay: s.rate = 0.33
        case .arc: s.angle = 12; s.hold = 2.4
        case .lens: s.zoom = 5
        default: break
        }
        return s
    }

    /// The controls the inspector offers for a move, in order.
    enum Control: Hashable, Sendable {
        case zoom(ClosedRange<Double>, String)
        case strength(String)
        case rate([Double])
        case hold(ClosedRange<Double>)
        case angle(ClosedRange<Double>)
        case alternate(String, String, String)
        case smooth(String)
        case target
        case ending
        case smoothMotion
    }

    static func controls(for move: ShotCameraMove) -> [Control] {
        // Tilt Punch already settles back to level, and Frozen Arc swings back to the real view.
        let ending: [Control] = move == .tilt || move == .arc ? [] : [.ending]
        return moveControls(move) + ending
    }

    private static func moveControls(_ move: ShotCameraMove) -> [Control] {
        switch move {
        case .follow: [.zoom(1.4...3.2, "Max zoom"), .alternate("Framing", "Smooth", "Tight"), .target]
        case .chase: [.zoom(2...4.5, "Max zoom"), .strength("Whip blur")]
        case .broadcast: [.zoom(1.6...3.2, "Push-in"), .strength("Operator lag")]
        case .handoff: [.zoom(1.6...3.2, "Ball zoom"), .strength("Whip blur")]
        case .split: [.zoom(1.6...3.6, "Ball cam zoom"), .alternate("Layout", "Side by side", "Stacked")]
        case .duo: [.zoom(1.6...3.4, "Ball zoom")]
        case .impact: [.zoom(1.3...3, "Punch"), .strength("Flash + shake"), .target]
        case .tilt: [.angle(0.5...8), .alternate("Direction", "Left", "Right")]
        case .recoil: [.angle(1...8), .strength("Shake")]
        case .ripple: [.strength("Ripple")]
        case .warp: [.strength("Speed burst")]
        case .ramp: [.rate([0.1, 0.25, 0.33, 0.5]), .smoothMotion, .smooth("Ease in and out")]
        case .freeze: [.hold(0.4...3), .smooth("Keep the path while it flies")]
        case .arc: [.angle(4...20), .hold(1...4), .alternate("Swing", "Right first", "Left first")]
        case .replay: [.rate([0.1, 0.25, 0.33, 0.5]), .smoothMotion, .zoom(1.2...3, "Replay zoom")]
        case .lens: [.zoom(2...7, "Magnification"), .alternate("Lens side", "Left", "Right")]
        case .spotlight: [.strength("Darkness")]
        case .focus: [.strength("Blur")]
        case .strobe: [.strength("Stamps")]
        case .lock: [.alternate("Readout", "Flight time", "Off")]
        }
    }
}

nonisolated struct ShotCameraPoint: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var cgPoint: CGPoint { CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y))) }
}
