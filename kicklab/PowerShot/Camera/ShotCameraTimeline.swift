import AVFoundation
import SwiftUI

/// The camera editor's timeline. The playhead stays in the middle and the shot slides under it:
/// drag to scrub frame by frame, pinch to zoom. Under the filmstrip sits the camera track, where
/// a tapped block can be dragged to move or trimmed by its handles. Everything snaps to real
/// source frames and magnetises to the strike, the playhead and neighbouring blocks.
struct ShotCameraTimeline: View {
    @Binding var track: ShotCameraTrack
    @Binding var selection: UUID?
    /// Playhead, in source seconds.
    let time: Double
    let duration: Double
    let strike: Double
    /// The strike found from the ball's flight; a double tap on the flag goes back to it.
    var foundStrike: Double? = nil
    let frames: ShotSourceFrames
    let source: URL?
    let onSeek: (Double) -> Void
    /// A gesture that changes the track started or ended (undo checkpoints, pausing playback).
    let onEditBegan: () -> Void
    let onEditEnded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom = 1.0
    @State private var pinchBase: Double?
    @State private var scrubOrigin: Double?
    @State private var dragOrigin: ShotCameraClip?
    /// The track and strike as a strike drag found them; the blocks ride along from there.
    @State private var strikeOrigin: (track: ShotCameraTrack, strike: Double)?
    @State private var thumbnails: [CGImage?] = []
    @State private var frameTick = 0
    @State private var snapTick = 0
    @State private var lastTickKey = Int.min
    @State private var snapped: Double?

    static let rulerHeight: CGFloat = 16, stripHeight: CGFloat = 42, laneHeight: CGFloat = 36
    static var height: CGFloat { rulerHeight + stripHeight + 8 + laneHeight + 4 }
    private let tileCount = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let pps = pointsPerSecond(width: width)
            ZStack(alignment: .topLeading) {
                ruler(width: width, pps: pps)
                filmstrip(width: width, pps: pps)
                    .offset(y: Self.rulerHeight)
                lane(width: width, pps: pps)
                    .offset(y: Self.rulerHeight + Self.stripHeight + 8)
                strikeFlag(width: width, pps: pps)
                strikeBeacon(width: width, pps: pps)
                playhead(width: width)
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .clipped()
            .contentShape(.rect)
            .gesture(scrub(pps: pps))
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if pinchBase == nil { pinchBase = zoom }
                zoom = min(24, max(1, (pinchBase ?? 1) * value.magnification))
            }.onEnded { _ in pinchBase = nil })
            .onTapGesture { withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { selection = nil } }
        }
        .frame(height: Self.height)
        .sensoryFeedback(.selection, trigger: frameTick)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: snapTick)
        .task(id: source?.absoluteString ?? "") { await loadThumbnails() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shot-camera-timeline")
    }

    // MARK: Geometry

    /// At 1× the whole shot is about two screen-widths; pinching zooms to single frames.
    private func pointsPerSecond(width: CGFloat) -> Double {
        Double(width) / max(1.2, min(duration, 2.6)) * zoom
    }
    private func x(_ t: Double, width: CGFloat, pps: Double) -> CGFloat { width / 2 + CGFloat((t - time) * pps) }
    private var frameDuration: Double { frames.isEmpty ? 1.0 / 60 : max(1.0 / 240, frames.frameDuration(at: time)) }
    private func quantize(_ t: Double) -> Double { frames.isEmpty ? min(duration, max(0, t)) : frames.nearest(min(duration, max(0, t))) }

    /// Snap targets: the strike, the playhead, the ends, and every block edge but the moving one.
    private func snaps(excluding id: UUID? = nil, includePlayhead: Bool = true) -> [Double] {
        var points = [strike, 0, duration]
        if includePlayhead { points.append(time) }
        for clip in track.clips where clip.id != id { points += [clip.start, clip.end] }
        return points
    }

    // MARK: Layers

    private func ruler(width: CGFloat, pps: Double) -> some View {
        Canvas { context, size in
            let perFrame = pps * frameDuration
            // Frames when there is room, otherwise tenths of a second.
            let step = perFrame >= 7 ? frameDuration : perFrame >= 2 ? frameDuration * 5 : 0.1
            let labelEvery = pps > 900 ? 0.1 : pps > 320 ? 0.25 : pps > 150 ? 0.5 : 1
            let visible = Double(width) / pps
            var t = max(0, ((time - visible / 2) / step).rounded(.down) * step)
            let end = min(duration, time + visible / 2 + step)
            while t <= end {
                let px = x(t, width: width, pps: pps)
                let isLabel = abs((t / labelEvery).rounded() * labelEvery - t) < step / 2
                var tick = Path()
                tick.move(to: CGPoint(x: px, y: size.height - (isLabel ? 7 : 4)))
                tick.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(tick, with: .color(.white.opacity(isLabel ? 0.5 : 0.22)), lineWidth: 1)
                if isLabel {
                    context.draw(Text(String(format: labelEvery < 0.5 ? "%.2f" : "%.1f", t)).font(.system(size: 8.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45)), at: CGPoint(x: px, y: 5))
                }
                t += step
            }
        }
        .frame(width: width, height: Self.rulerHeight)
        .allowsHitTesting(false)
    }

    private func filmstrip(width: CGFloat, pps: Double) -> some View {
        let left = x(0, width: width, pps: pps), full = CGFloat(duration * pps)
        let tile = full / CGFloat(tileCount)
        return HStack(spacing: 0) {
            ForEach(0..<tileCount, id: \.self) { i in
                Group {
                    if thumbnails.indices.contains(i), let image = thumbnails[i] {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.white.opacity(i % 2 == 0 ? 0.06 : 0.04))
                    }
                }
                .frame(width: tile, height: Self.stripHeight).clipped()
            }
        }
        .frame(width: full, height: Self.stripHeight)
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        // The selected block's time is lit on the filmstrip too.
        .overlay(alignment: .topLeading) {
            if let clip = track.clip(selection) {
                Rectangle().fill(clip.move.tint.opacity(0.18))
                    .overlay(alignment: .leading) { Rectangle().fill(clip.move.tint).frame(width: 1.5) }
                    .overlay(alignment: .trailing) { Rectangle().fill(clip.move.tint).frame(width: 1.5) }
                    .frame(width: CGFloat(clip.length * pps), height: Self.stripHeight)
                    .offset(x: CGFloat(clip.start * pps))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .offset(x: left)
        .allowsHitTesting(false)
    }

    private func lane(width: CGFloat, pps: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.035))
                .frame(width: CGFloat(duration * pps), height: Self.laneHeight)
                .offset(x: x(0, width: width, pps: pps))
            if track.isEmpty {
                Text("Pick a move below. It lands on the strike.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                    .frame(width: width, height: Self.laneHeight)
                    .transition(.opacity)
            }
            ForEach(track.clips) { clip in
                block(clip, width: width, pps: pps)
                    .transition(.asymmetric(insertion: .scale(scale: 0.4, anchor: .bottom).combined(with: .opacity),
                                            removal: .scale(scale: 0.7).combined(with: .opacity)))
            }
        }
        .frame(width: width, height: Self.laneHeight, alignment: .topLeading)
    }

    private func block(_ clip: ShotCameraClip, width: CGFloat, pps: Double) -> some View {
        let left = x(clip.start, width: width, pps: pps)
        let w = max(18, CGFloat(clip.length * pps))
        let selected = selection == clip.id
        let tint = clip.move.tint
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [tint.opacity(selected ? 0.95 : 0.7), tint.opacity(selected ? 0.75 : 0.5)],
                                     startPoint: .top, endPoint: .bottom))
            HStack(spacing: 5) {
                Image(systemName: clip.move.symbol).font(.system(size: 11, weight: .bold))
                // Narrow blocks keep what matters: a retimed block's speed, otherwise its name.
                if w > 104 || (w > 58 && badge(clip) == nil) {
                    Text(clip.move.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let badge = badge(clip), w > 58 && (w <= 104 || w > 150) {
                    Text(badge).font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.22), in: .capsule)
                }
            }
            .foregroundStyle(.black.opacity(0.82))
            .padding(.horizontal, selected ? 16 : 8)
        }
        .frame(width: w, height: Self.laneHeight)
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 2)
        }
        .overlay(alignment: .leading) { if selected { handle(clip, edge: .start, pps: pps) } }
        .overlay(alignment: .trailing) { if selected { handle(clip, edge: .end, pps: pps) } }
        .shadow(color: tint.opacity(selected ? 0.45 : 0), radius: 10, y: 2)
        .scaleEffect(selected ? 1 : 0.94, anchor: .center)
        .offset(x: left)
        .contentShape(.rect(cornerRadius: 9))
        .onTapGesture {
            withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                selection = selection == clip.id ? nil : clip.id
            }
        }
        .highPriorityGesture(moveGesture(clip, pps: pps), including: selected ? .all : .none)
        .contextMenu {
            Button("Preview from here", systemImage: "play") { onSeek(clip.start) }
            Button("Delete", systemImage: "trash", role: .destructive) {
                onEditBegan()
                withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) { track.remove(clip.id); if selection == clip.id { selection = nil } }
                onEditEnded()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clip.move.title), \(ShotSourceFrames.label(clip.start)) to \(ShotSourceFrames.label(clip.end))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("shot-camera-block-\(clip.move.rawValue)")
    }

    private func badge(_ clip: ShotCameraClip) -> String? {
        switch clip.move {
        case .ramp: String(format: "×%.2g", clip.settings.rate)
        case .freeze: String(localized: "\(clip.settings.hold.formatted(.number.precision(.fractionLength(1)))) s hold")
        case .replay: String(format: "↺ ×%.2g", clip.settings.rate)
        default: nil
        }
    }

    private func handle(_ clip: ShotCameraClip, edge: ShotCameraTrack.Edge, pps: Double) -> some View {
        Capsule().fill(.white).frame(width: 5, height: 22)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .frame(width: 30, height: Self.laneHeight)
            .contentShape(.rect)
            .offset(x: edge == .start ? -9 : 9)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragOrigin == nil { dragOrigin = clip; onEditBegan() }
                guard let origin = dragOrigin else { return }
                let base = edge == .start ? origin.start : origin.end
                let requested = quantize(base + Double(value.translation.width) / pps)
                var next = track
                next.trim(clip.id, edge: edge, to: requested, duration: duration,
                          snaps: snaps(excluding: clip.id), within: 10 / pps)
                guard let moved = next.clip(clip.id) else { return }
                noteSnap(edge == .start ? moved.start : moved.end, among: snaps(excluding: clip.id), pps: pps)
                track = next
            }.onEnded { _ in dragOrigin = nil; snapped = nil; onEditEnded() })
            .accessibilityLabel(edge == .start ? "Start handle" : "End handle")
    }

    private func moveGesture(_ clip: ShotCameraClip, pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 3).onChanged { value in
            if dragOrigin == nil { dragOrigin = clip; onEditBegan() }
            guard let origin = dragOrigin else { return }
            var next = track
            next.move(clip.id, toStart: quantize(origin.start + Double(value.translation.width) / pps), duration: duration,
                      snaps: snaps(excluding: clip.id), within: 10 / pps)
            guard let moved = next.clip(clip.id) else { return }
            let points = snaps(excluding: clip.id)
            noteSnap(points.contains { abs($0 - moved.start) < 0.0005 } ? moved.start : moved.end, among: points, pps: pps)
            track = next
        }.onEnded { _ in dragOrigin = nil; snapped = nil; onEditEnded() }
    }

    private func strikeFlag(width: CGFloat, pps: Double) -> some View {
        let px = x(strike, width: width, pps: pps)
        let auto = track.strike == nil
        let lime = Color(red: 0.8, green: 1, blue: 0.43)
        return ZStack(alignment: .top) {
            Rectangle().fill(lime).frame(width: 1.5, height: Self.stripHeight + 6)
                .offset(y: Self.rulerHeight - 3)
                .allowsHitTesting(false)
            // The flag is the handle. Its touch area is set before the offset below, so it travels with
            // the flag instead of staying at the timeline's left edge.
            HStack(spacing: 3) {
                Image(systemName: "flag.fill").font(.system(size: 7, weight: .bold))
                Text(auto ? "STRIKE" : "STRIKE ✎").font(.system(size: 8, weight: .heavy)).tracking(0.6)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 5).frame(height: 14)
            .background(lime, in: .capsule)
            .offset(y: 1)
            .frame(width: 70, height: 22, alignment: .top)
            .contentShape(.rect)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                if strikeOrigin == nil { strikeOrigin = (track, strike); onEditBegan() }
                guard let origin = strikeOrigin else { return }
                let t = quantize(origin.strike + Double(value.translation.width) / pps)
                guard track.strike != t else { return }
                var next = origin.track
                next.moveStrike(from: origin.strike, to: t, duration: duration)
                track = next
                frameTick += 1
            }.onEnded { _ in strikeOrigin = nil; onEditEnded() })
            .onTapGesture(count: 2) {
                onEditBegan()
                var next = track
                next.moveStrike(from: strike, to: foundStrike ?? strike, duration: duration)
                next.strike = nil
                track = next
                onEditEnded()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(auto ? String(localized: "Strike at \(ShotSourceFrames.label(strike)), found automatically")
                                     : String(localized: "Strike at \(ShotSourceFrames.label(strike))"))
            .accessibilityHint("Drag to move the strike; the moves on it come along. Double-tap to go back to the found strike.")
            .accessibilityIdentifier("shot-camera-strike")
        }
        .frame(width: 70, alignment: .top)
        .offset(x: px - 35)
    }

    /// When the strike is out of view, a marker at that edge points to it; a tap brings it back.
    @ViewBuilder private func strikeBeacon(width: CGFloat, pps: Double) -> some View {
        let px = x(strike, width: width, pps: pps)
        if px < 8 || px > width - 8 {
            let left = px < 8
            Button { onSeek(strike) } label: {
                HStack(spacing: 2) {
                    if left { Image(systemName: "chevron.left").font(.system(size: 7, weight: .heavy)) }
                    Image(systemName: "flag.fill").font(.system(size: 7, weight: .bold))
                    if !left { Image(systemName: "chevron.right").font(.system(size: 7, weight: .heavy)) }
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 5).frame(height: 14)
                .background(Color(red: 0.8, green: 1, blue: 0.43), in: .capsule)
                .frame(width: 44, height: 22, alignment: left ? .leading : .trailing)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .offset(x: left ? 0 : width - 44, y: 1)
            .transition(.opacity)
            .accessibilityLabel("Go to the strike")
            .accessibilityIdentifier("shot-camera-go-to-strike")
        }
    }

    private func playhead(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle().fill(.white).frame(width: 9, height: 9)
            Rectangle().fill(.white).frame(width: 2)
        }
        .frame(width: 9, height: Self.height - 2)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .offset(x: width / 2 - 4.5, y: 2)
        .allowsHitTesting(false)
    }

    // MARK: Gestures

    private func scrub(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 2).onChanged { value in
            if scrubOrigin == nil { scrubOrigin = time; onEditBegan() }
            var t = (scrubOrigin ?? time) - Double(value.translation.width) / pps
            // The strike and block edges pull the playhead in.
            let points = snaps(includePlayhead: false)
            if let s = ShotCameraTrack.snap(t, to: points, within: 9 / pps) { t = s }
            t = quantize(t)
            noteSnap(t, among: points, pps: pps)
            tickIfNeeded(t, pps: pps)
            onSeek(t)
        }.onEnded { _ in scrubOrigin = nil; snapped = nil; onEditEnded() }
    }

    /// A light haptic each time a frame (or a tenth of a second, zoomed out) passes the playhead.
    private func tickIfNeeded(_ t: Double, pps: Double) {
        let key = pps * frameDuration >= 5 ? frames.index(at: t) : Int((t * 10).rounded(.down))
        if key != lastTickKey { lastTickKey = key; frameTick += 1 }
    }
    /// A firmer haptic the moment an edge lands on a snap point.
    private func noteSnap(_ t: Double, among points: [Double], pps: Double) {
        let hit = points.first { abs($0 - t) < 0.0005 }
        if let hit, snapped.map({ abs($0 - hit) > 0.0005 }) ?? true { snapTick += 1 }
        snapped = hit
    }

    private func loadThumbnails() async {
        thumbnails = Array(repeating: nil, count: tileCount)
        guard let source else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 140, height: 140)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        for i in 0..<tileCount {
            guard !Task.isCancelled else { return }
            let t = duration * (Double(i) + 0.5) / Double(tileCount)
            let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            guard !Task.isCancelled, thumbnails.indices.contains(i) else { return }
            thumbnails[i] = image
        }
    }
}
