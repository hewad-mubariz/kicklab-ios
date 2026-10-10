import CoreGraphics
import Foundation
import simd

nonisolated enum ShotCameraStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, follow, impact, ramp, tilt, lens, freeze, split, frames
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Original"
        case .follow: "Ball Follow"
        case .impact: "Impact Zoom"
        case .ramp: "Speed Ramp"
        case .tilt: "Tilt Punch"
        case .lens: "Contact Lens"
        case .freeze: "Freeze + Path"
        case .split: "Wide + Detail"
        case .frames: "Frame Steps"
        }
    }
    var symbol: String {
        switch self {
        case .none: "video"
        case .follow: "scope"
        case .impact: "arrow.up.left.and.arrow.down.right"
        case .ramp: "slowmo"
        case .tilt: "rotate.left"
        case .lens: "magnifyingglass"
        case .freeze: "pause.rectangle"
        case .split: "rectangle.split.2x1"
        case .frames: "film.stack"
        }
    }
    var detail: String {
        switch self {
        case .none: "Keep the original framing."
        case .follow: "A smooth crop follows the ball. When tracking is lost, the view eases back to wide."
        case .impact: "Push in at the strike, then ease back out."
        case .ramp: "Slow a selected part of the shot, then return to normal playback."
        case .tilt: "A small tilt at the strike that settles back to level."
        case .lens: "Inspect the foot and ball in a magnifier while keeping the wide view."
        case .freeze: "Hold the strike frame, with the observed path and initial direction over the video."
        case .split: "Synchronized wide footage and a crop following the ball."
        case .frames: "Jump between source frames to inspect the strike and the flight."
        }
    }
    var needsStrike: Bool { [.impact, .ramp, .tilt, .lens, .freeze, .frames].contains(self) }
    var needsBall: Bool { [.follow, .impact, .lens, .split].contains(self) }
    var changesExport: Bool { self != .none && self != .frames }
}

nonisolated struct ShotCameraSettings: Equatable, Codable, Sendable {
    var style: ShotCameraStyle = .none
    var strength = 1.0
    /// A source-video timestamp; automatic movement detection remains an estimate.
    var strike: Double?
    var ranges: [ShotCameraStyle: ShotSourceRange] = [:]
    var followZoom = 1.75
    var tightFollow = false
    var followTarget: ShotCameraPoint?
    var impactZoom = 1.8
    var impactDuration = 0.7
    var punchyImpact = false
    var impactTarget: ShotCameraPoint?
    var rampRate = 0.25
    var smoothRamp = false
    var tiltAngle = 2.5
    var tiltRight = false
    var tiltDuration = 0.7
    var lensZoom = 3.2
    var lensSize: ShotLensSize = .medium
    var lensTarget: ShotCameraPoint?
    var lensPosition = ShotCameraPoint(x: 0.78, y: 0.25)
    var freezeFrame: Double?
    var freezeHold = 0.65
    var showPath = true
    var showDirection = true
    var pathEnd: Double?
    var splitZoom = 1.75
    var stackedSplit = false
    var splitBalance = 0.5

    func strikeTime(track: BallEffectTrack, flight: ShotFlight?) -> Double {
        max(0, strike ?? flight?.launch ?? track.samples.first?.time ?? 0)
    }
    func range(for style: ShotCameraStyle, strike: Double, duration: Double) -> ShotSourceRange {
        let fallback = style == .ramp ? ShotSourceRange(start: strike - 0.1, end: strike + 0.18) : ShotSourceRange(start: 0, end: duration)
        return (ranges[style] ?? fallback).clamped(to: duration)
    }
    var hasManualTarget: Bool {
        switch style {
        case .follow, .split: followTarget != nil
        case .impact: impactTarget != nil
        case .lens: lensTarget != nil
        default: false
        }
    }
}

nonisolated struct ShotSourceRange: Equatable, Codable, Sendable {
    var start: Double
    var end: Double
    func clamped(to duration: Double) -> Self {
        let a = min(max(0, start), max(0, duration))
        return Self(start: a, end: min(max(a, end), max(a, duration)))
    }
    func contains(_ time: Double) -> Bool { time >= start - 0.00001 && time <= end + 0.00001 }
}

nonisolated struct ShotCameraPoint: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var cgPoint: CGPoint { CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y))) }
}
nonisolated enum ShotLensSize: String, Codable, CaseIterable, Sendable {
    case small = "Small", medium = "Medium", large = "Large"
    var radius: Double { self == .small ? 0.14 : self == .medium ? 0.20 : 0.27 }
}

enum ShotCameraSpatialEdit: String, Identifiable {
    case follow, impact, lensArea, lensPosition
    var id: String { rawValue }
    var showsSource: Bool { self != .lensPosition }
    var title: String {
        switch self {
        case .follow: "Drag to set the crop centre"
        case .impact: "Drag to set the zoom target"
        case .lensArea: "Drag to choose the area to inspect"
        case .lensPosition: "Drag to place the lens"
        }
    }
}

/// All coordinates are upright source-image coordinates, never ground metres.
/// This deterministic plan is used by the preview and the exported pixels.
nonisolated struct ShotCameraFrame: Sendable {
    struct Uniforms: Sendable {
        var viewport: SIMD4<Float>
        var crop: SIMD4<Float>
        var lens: SIMD4<Float>
        var guide: SIMD4<Float>
        /// Lens position and radius (fraction of the short edge), then split orientation/balance.
        var inset: SIMD4<Float>
        var layout: SIMD4<Float>
    }
    var uniforms: Uniforms
    var path: [SIMD4<Float>]
    var isActive: Bool { uniforms.viewport.z > 0 }

    static func make(settings: ShotCameraSettings, track: BallEffectTrack, flight: ShotFlight?,
                     size: CGSize, time: Double) -> ShotCameraFrame {
        let w = max(1, Double(size.width)), h = max(1, Double(size.height))
        let strength = min(1.4, max(0.6, settings.strength))
        let strike = settings.strikeTime(track: track, flight: flight)
        func pulse(duration: Double, punchy: Bool = false) -> Double {
            let half = max(0.05, duration / 2)
            let t = abs(time - strike) / half
            guard t < 1 else { return 0 }
            return punchy ? pow(1 - t, 3) : (1 + cos(.pi * t)) / 2
        }
        let impact = pulse(duration: settings.impactDuration, punchy: settings.punchyImpact)
        var mode: Float = 0, center = CGPoint(x: 0.5, y: 0.5), zoom = 1.0, angle = 0.0
        var lens = SIMD4<Float>(0.5, 0.5, 0, 0), guide = SIMD4<Float>.zero
        var path: [SIMD4<Float>] = []
        let range = settings.ranges[settings.style]
        let inRange = range?.contains(time) ?? true
        let radius = settings.lensSize.radius * min(w, h)
        let insetX = min(1 - radius / w, max(radius / w, settings.lensPosition.x))
        let insetY = min(1 - radius / h, max(radius / h, settings.lensPosition.y))
        let balance = min(0.75, max(0.25, settings.splitBalance))

        func reliable(_ t: Double) -> BallStyleSample? {
            guard let sample = track.sample(at: t), sample.confidence >= 0.05 else { return nil }
            return sample
        }
        func follow() -> (CGPoint, Double)? {
            if let target = settings.followTarget { return (target.cgPoint, 1) }
            var fade = 1.0
            let current: BallStyleSample
            if let seen = reliable(time) { current = seen }
            else if let recent = track.samples.last(where: { $0.time <= time && time - $0.time < 0.4 }) {
                current = recent
                fade = pow(max(0, 1 - (time - recent.time) / 0.4), 2)
            } else { return nil }
            let offsets = settings.tightFollow ? [0.0] : [-0.08, -0.04, 0, 0.04, 0.08]
            let neighbors = offsets.compactMap { offset -> BallStyleSample? in
                guard let p = reliable(current.time + offset),
                      hypot(p.center.x - current.center.x, p.center.y - current.center.y) < 0.2 else { return nil }
                return p
            }
            let n = Double(max(1, neighbors.count))
            let x = neighbors.isEmpty ? current.center.x : neighbors.reduce(0) { $0 + $1.center.x } / n
            let y = neighbors.isEmpty ? current.center.y : neighbors.reduce(0) { $0 + $1.center.y } / n
            return (CGPoint(x: 0.5 + (x - 0.5) * fade, y: 0.5 + (y - 0.5) * fade), fade)
        }
        switch settings.style {
        case .follow, .split:
            if inRange, let (target, fade) = follow() {
                mode = settings.style == .split ? 6 : 1
                center = target
                zoom = 1 + (max(1, settings.style == .split ? settings.splitZoom : settings.followZoom) - 1) * strength * fade
            } else if inRange, settings.style == .split {
                // Preserve the two-panel layout through an occlusion; detail eases back to wide.
                mode = 6
            }
        case .impact:
            if impact > 0, let target = settings.impactTarget?.cgPoint ?? reliable(strike)?.center {
                mode = 2
                center = CGPoint(x: 0.5 + (target.x - 0.5) * impact,
                                 y: 0.5 + (target.y - 0.5) * impact)
                zoom = 1 + (max(1, settings.impactZoom) - 1) * strength * impact
            }
        case .tilt:
            let tilt = pulse(duration: settings.tiltDuration)
            mode = tilt > 0 ? 3 : 0
            angle = (settings.tiltRight ? 1 : -1) * min(12, max(0, settings.tiltAngle)) * strength * tilt * .pi / 180
            zoom = 1 + 0.1 * strength * tilt
        case .lens:
            if inRange, let target = settings.lensTarget?.cgPoint ?? reliable(strike)?.center {
                mode = 4
                // Fixed to the contact area, so the foot stays visible during replay.
                lens = SIMD4(Float(target.x), Float(target.y), Float(max(1, settings.lensZoom) * strength), 1)
            }
        case .freeze:
            let frozen = settings.freezeFrame ?? strike
            mode = abs(time - frozen) < 0.0001 ? 5 : 0
            let end = max(frozen, settings.pathEnd ?? flight?.end ?? frozen + 2)
            let observations = track.samples.filter { $0.time >= frozen && $0.time <= end && $0.confidence >= 0.05 }
            var segments: [Int] = [], segment = 0
            for i in observations.indices {
                if i > 0, !EffectFrame.bridges(observations[i - 1], observations[i]) { segment += 1 }
                segments.append(segment)
            }
            let count = min(64, observations.count)
            var lastSegment: Int?
            for i in 0..<count {
                let index = count == 1 ? 0 : Int((Double(i) * Double(observations.count - 1) / Double(count - 1)).rounded())
                let p = observations[index]
                path.append(SIMD4(Float(p.center.x), Float(p.center.y), lastSegment == segments[index] ? 1 : 0, 0))
                lastSegment = segments[index]
            }
            if settings.showDirection, observations.count > 1, EffectFrame.bridges(observations[0], observations[1]) {
                let a = observations[0].center
                let firstSegmentEnd = segments.firstIndex(where: { $0 != segments[0] }) ?? observations.count
                let b = observations[min(4, firstSegmentEnd - 1)].center
                let dx = (b.x - a.x) * w, dy = (b.y - a.y) * h, length = hypot(dx, dy)
                if length > 0.01 { guide = SIMD4(Float(a.x), Float(a.y), Float(dx / length), Float(dy / length)) }
            }
            if !settings.showPath { path = [] }
        case .none, .ramp, .frames: break
        }

        // The rotated crop must remain inside the recorded image, including at its edges.
        let pw = mode == 6 && !settings.stackedSplit ? w * (1 - balance) : w
        let ph = mode == 6 && settings.stackedSplit ? h * (1 - balance) : h
        let fit = max(pw / w, ph / h)
        let c = abs(cos(angle)), s = abs(sin(angle))
        zoom = max(zoom, max((pw * c + ph * s) / (w * fit), (ph * c + pw * s) / (h * fit)))
        let rx = min(0.5, (pw * c + ph * s) / (2 * fit * zoom * w))
        let ry = min(0.5, (ph * c + pw * s) / (2 * fit * zoom * h))
        center.x = min(1 - rx, max(rx, center.x))
        center.y = min(1 - ry, max(ry, center.y))
        return ShotCameraFrame(uniforms: Uniforms(
            viewport: SIMD4(Float(w), Float(h), mode, Float(path.count)),
            crop: SIMD4(Float(center.x), Float(center.y), Float(zoom), Float(angle)),
            lens: lens, guide: guide,
            inset: SIMD4(Float(insetX), Float(insetY), Float(settings.lensSize.radius), 0),
            layout: SIMD4(settings.stackedSplit ? 1 : 0, Float(balance), 0, 0)), path: path)
    }
}
