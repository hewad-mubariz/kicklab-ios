import SwiftUI

/// The Camera page of the Power Shot editor: transport, the frame-accurate timeline with its
/// camera track, and below it either the move carousel or the selected block's controls.
struct ShotCameraEditor: View {
    @Binding var track: ShotCameraTrack
    @Binding var selection: UUID?
    @Binding var original: Bool
    /// The block whose fixed target is being placed on the video.
    @Binding var targetEdit: UUID?
    let plan: ShotCameraPlan?
    /// The strike frame, for the move cards.
    let still: CGImage?
    let duration: Double
    let frames: ShotSourceFrames
    let source: URL?
    let time: Double
    let isPlaying: Bool
    let hasBallTrack: Bool
    let onSeek: (Double) -> Void
    let onTogglePlayback: () -> Void
    /// Plays one block from just before it to just after it.
    let onPreview: (ShotCameraClip) -> Void
    /// Smooth slow-motion frames are being made in the background.
    var makingSmoothMotion = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [ShotCameraTrack] = []
    @State private var future: [ShotCameraTrack] = []
    @State private var checkpoint: ShotCameraTrack?
    @State private var replacing = false
    @State private var dropTick = 0

    private var strike: Double { plan?.strike ?? track.strike ?? 0 }
    private var flightEnd: Double { plan?.flightEnd ?? min(duration, strike + 1.2) }
    private var selected: ShotCameraClip? { track.clip(selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            transport.padding(.horizontal, 16)
            ShotCameraTimeline(track: $track, selection: $selection, time: time, duration: duration, strike: strike,
                               foundStrike: plan?.foundStrike, frames: frames, source: source, onSeek: onSeek,
                               onEditBegan: began, onEditEnded: ended)
                .padding(.horizontal, 16)
            ZStack(alignment: .top) {
                if let clip = selected, !replacing {
                    inspector(clip)
                        .id(clip.id)
                        .transition(.asymmetric(insertion: .push(from: .bottom).combined(with: .opacity), removal: .opacity))
                } else {
                    ShotMoveCarousel(replacing: replacing ? selected?.move : nil, image: still,
                                     flight: plan?.flightSketch() ?? [], hasBall: hasBallTrack,
                                     hasKicker: plan?.hasKicker ?? false, onPick: pick)
                        .overlay(alignment: .topTrailing) {
                            if replacing {
                                Button("Cancel") { withAnimation(motion(SessionMotion.snap)) { replacing = false } }
                                    .font(.system(size: 11, weight: .semibold)).buttonStyle(.glass)
                                    .padding(.trailing, 16).offset(y: -2)
                            }
                        }
                        .transition(.asymmetric(insertion: .push(from: .top).combined(with: .opacity), removal: .opacity))
                }
            }
        }
        .animation(motion(SessionMotion.tray), value: selection)
        .animation(motion(SessionMotion.tray), value: replacing)
        .sensoryFeedback(.impact(weight: .medium), trigger: dropTick)
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection) { _, next in if next == nil { replacing = false } }
    }

    private func motion(_ animation: Animation) -> Animation? { SessionMotion.animation(animation, reduceMotion: reduceMotion) }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 6) {
            roundButton(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play", id: "play", prominent: true,
                        action: onTogglePlayback)
            VStack(alignment: .leading, spacing: 1) {
                Text(ShotSourceFrames.label(time)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: time))
                    .accessibilityIdentifier("shot-camera-time")
                Text(timeDetail).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1).fixedSize().layoutPriority(1)
            .padding(.leading, 4)
            .animation(motion(SessionMotion.snap), value: time)
            Spacer(minLength: 2)
            stepButton(-1)
            stepButton(1)
            strikeButton
            compareButton
            roundButton("arrow.uturn.backward", label: "Undo", id: "undo", action: undo)
                .disabled(history.isEmpty).opacity(history.isEmpty ? 0.35 : 1)
        }
    }

    private func roundButton(_ symbol: String, label: String, id: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: 32, height: 32)
                .background(prominent ? AnyShapeStyle(SessionStyle.mint) : AnyShapeStyle(.white.opacity(0.1)), in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(SessionPressStyle(scale: 0.88))
        .accessibilityLabel(label)
        .accessibilityIdentifier("shot-camera-\(id)")
    }

    private var timeDetail: String {
        let frame = frames.isEmpty ? "" : String(localized: "Frame \(frames.index(at: time) + 1)") + " · "
        let offset = time - strike
        let half = frames.isEmpty ? 0.004 : frames.frameDuration(at: strike) / 2
        if abs(offset) < half { return frame + String(localized: "⚑ Strike") }
        return frame + String(format: "⚑ %@%.2f s", offset > 0 ? "+" : "−", abs(offset))
    }

    private var onStrike: Bool { abs(time - strike) < (frames.isEmpty ? 0.004 : frames.frameDuration(at: strike) / 2) }

    /// Puts the strike on the frame under the playhead; the moves placed on it come along.
    private var strikeButton: some View {
        Button {
            began()
            var next = track
            next.moveStrike(from: strike, to: time, duration: duration)
            withAnimation(motion(SessionMotion.snap)) { track = next }
            ended()
        } label: {
            Image(systemName: "flag.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(onStrike ? .black : .white)
                .frame(width: 32, height: 32)
                .background(onStrike ? AnyShapeStyle(Color(red: 0.8, green: 1, blue: 0.43)) : AnyShapeStyle(.white.opacity(0.1)), in: .circle)
        }
        .buttonStyle(SessionPressStyle(scale: 0.88))
        .disabled(onStrike)
        .sensoryFeedback(.impact(weight: .medium), trigger: strike)
        .accessibilityLabel(onStrike ? "The strike is on this frame" : "Set the strike to this frame")
        .accessibilityIdentifier("shot-camera-set-strike")
    }

    private func stepButton(_ delta: Int) -> some View {
        Button { onSeek(frames.isEmpty ? min(duration, max(0, time + Double(delta) / 60)) : frames.adjacent(to: time, by: delta)) } label: {
            Image(systemName: delta < 0 ? "backward.frame.fill" : "forward.frame.fill").font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: .circle)
        }
        .buttonStyle(SessionPressStyle(scale: 0.88))
        .buttonRepeatBehavior(.enabled)
        .sensoryFeedback(.selection, trigger: time)
        .accessibilityLabel(delta < 0 ? "Previous frame" : "Next frame")
        .accessibilityIdentifier(delta < 0 ? "shot-camera-previous-frame" : "shot-camera-next-frame")
    }

    /// Hold to see the original framing; release to see the camera track again.
    private var compareButton: some View {
        Image(systemName: original ? "eye.slash.fill" : "eye").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(original ? .black : .white)
            .frame(width: 32, height: 32)
            .background(original ? AnyShapeStyle(Color.white) : AnyShapeStyle(.white.opacity(0.1)), in: .circle)
            .contentTransition(.symbolEffect(.replace))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                withAnimation(motion(SessionMotion.snap)) { original = pressing }
            })
            .sensoryFeedback(.impact(weight: .light), trigger: original)
            .accessibilityLabel("Hold to compare with the original")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { original.toggle() }
            .accessibilityIdentifier("shot-camera-compare")
    }

    // MARK: Editing

    private func began() { if checkpoint == nil { checkpoint = track } }
    private func ended() {
        guard let start = checkpoint else { return }
        checkpoint = nil
        if start != track { history.append(start); if history.count > 40 { history.removeFirst() }; future.removeAll() }
    }
    private func undo() {
        guard let last = history.popLast() else { return }
        future.append(track)
        withAnimation(motion(SessionMotion.pop)) {
            track = last
            if track.clip(selection) == nil { selection = nil }
        }
    }

    private func quantized(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        guard !frames.isEmpty else { return range }
        let lo = frames.nearest(range.lowerBound), hi = max(frames.adjacent(to: lo, by: 3), frames.nearest(range.upperBound))
        return lo...hi
    }

    /// Adds a move where it belongs (around the strike, or the flight), or swaps the selected block's move.
    private func pick(_ move: ShotCameraMove) {
        began()
        if replacing, let id = selection {
            withAnimation(motion(SessionMotion.pop)) { track.replace(id, with: move); replacing = false }
            ended()
            dropTick += 1
            if let clip = track.clip(id) { onPreview(clip) }
            return
        }
        let preferred = move.defaultRange(strike: strike, flightEnd: flightEnd, playhead: time, duration: duration)
        // Moves fill free space beside what is there; only a full track makes a neighbour give way.
        let range = quantized(track.fit(preferred, duration: duration) ?? preferred)
        var next = track
        let id = next.insert(move, range: range, duration: duration)
        withAnimation(motion(SessionMotion.pop)) { track = next; selection = id }
        ended()
        dropTick += 1
        if let clip = track.clip(id) { onPreview(clip) }
    }

    // MARK: Inspector

    private func inspector(_ clip: ShotCameraClip) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: clip.move.symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(clip.move.tint)
                    .frame(width: 36, height: 36)
                    .background(clip.move.tint.opacity(0.16), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.move.title).font(.system(size: 15, weight: .semibold))
                    Text("\(seconds(clip.start)) – \(seconds(clip.end)) s · \(seconds(clip.length)) s long")
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                iconButton("play.fill", label: "Preview this move", id: "preview") { onPreview(clip) }
                iconButton("arrow.triangle.2.circlepath", label: "Change move", id: "change") {
                    withAnimation(motion(SessionMotion.snap)) { replacing = true }
                }
                iconButton("trash", label: "Delete move", id: "delete") {
                    began()
                    withAnimation(motion(SessionMotion.pop)) { track.remove(clip.id); selection = nil }
                    ended()
                }
                iconButton("checkmark", label: "Done", id: "done") {
                    withAnimation(motion(SessionMotion.snap)) { selection = nil }
                }
            }
            Text(clip.move.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(ShotMoveSettings.controls(for: clip.move).enumerated()), id: \.offset) { _, control in
                row(control, clip: clip)
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shot-camera-inspector")
    }

    private func iconButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: .circle)
        }
        .buttonStyle(SessionPressStyle(scale: 0.88))
        .accessibilityLabel(label)
        .accessibilityIdentifier("shot-camera-\(id)")
    }

    private func binding<Value>(_ clip: ShotCameraClip, _ keyPath: WritableKeyPath<ShotMoveSettings, Value>) -> Binding<Value> {
        Binding(get: { track.clip(clip.id)?.settings[keyPath: keyPath] ?? clip.settings[keyPath: keyPath] },
                set: { value in track.update(clip.id) { $0[keyPath: keyPath] = value } })
    }

    @ViewBuilder private func row(_ control: ShotMoveSettings.Control, clip: ShotCameraClip) -> some View {
        switch control {
        case .zoom(let range, let label):
            slider(label, value: binding(clip, \.zoom), range: range) { String(format: "%.1f×", $0) }
        case .strength(let label):
            slider(label, value: binding(clip, \.strength), range: 0.5...1.5) { String(localized: "\(Int(($0 * 100).rounded()))%") }
        case .hold(let range):
            slider(String(localized: "Hold"), value: binding(clip, \.hold), range: range) { String(format: "%.1f s", $0) }
        case .angle(let range):
            slider(String(localized: "Angle"), value: binding(clip, \.angle), range: range) { String(format: "%.1f°", $0) }
        case .rate(let options):
            HStack(spacing: 6) {
                Text("Speed").font(.system(size: 12, weight: .medium))
                Spacer()
                ForEach(options, id: \.self) { option in
                    chip(String(format: "×%.2g", option), selected: abs(clip.settings.rate - option) < 0.001) {
                        began(); track.update(clip.id) { $0.rate = option }; ended()
                    }
                }
            }
        case .alternate(let label, let off, let on):
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                chip(off, selected: !clip.settings.alternate) { began(); track.update(clip.id) { $0.alternate = false }; ended() }
                chip(on, selected: clip.settings.alternate) { began(); track.update(clip.id) { $0.alternate = true }; ended() }
            }
        case .smooth(let label):
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle(label, isOn: Binding(get: { clip.settings.smooth }, set: { value in
                    began(); track.update(clip.id) { $0.smooth = value }; ended()
                })).labelsHidden().tint(clip.move.tint)
            }
        case .smoothMotion:
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Smooth slow motion").font(.system(size: 12, weight: .medium))
                    Text(!ShotSlowMotion.isAvailable ? "Needs a newer iPhone"
                         : makingSmoothMotion && clip.settings.smoothMotion ? "Making smooth frames…" : "New in-between frames, like a TV replay")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Toggle("Smooth slow motion", isOn: Binding(get: { clip.settings.smoothMotion && ShotSlowMotion.isAvailable }, set: { value in
                    began(); track.update(clip.id) { $0.smoothMotion = value }; ended()
                })).labelsHidden().tint(clip.move.tint).disabled(!ShotSlowMotion.isAvailable)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shot-camera-smooth-motion")
        case .ending:
            HStack(spacing: 6) {
                Text("Ending").font(.system(size: 12, weight: .medium))
                Spacer()
                chip(String(localized: "Ease out"), selected: clip.settings.ending == .ease) { began(); track.update(clip.id) { $0.ending = .ease }; ended() }
                chip(String(localized: "Cut"), selected: clip.settings.ending == .cut) { began(); track.update(clip.id) { $0.ending = .cut }; ended() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shot-camera-ending")
        case .target:
            HStack(spacing: 6) {
                Text("Look at").font(.system(size: 12, weight: .medium))
                Spacer()
                chip(String(localized: "The ball"), selected: clip.settings.target == nil) { began(); track.update(clip.id) { $0.target = nil }; ended() }
                chip(targetEdit == clip.id ? String(localized: "Tap the video") : String(localized: "A point"), selected: clip.settings.target != nil || targetEdit == clip.id) {
                    withAnimation(motion(SessionMotion.snap)) { targetEdit = targetEdit == clip.id ? nil : clip.id }
                }
            }
        }
    }

    /// Two decimals in the viewer's number style.
    private func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12, weight: .medium)).frame(minWidth: 78, alignment: .leading)
            Slider(value: value, in: range) { editing in editing ? began() : ended() }
                .tint(SessionStyle.mint)
                .accessibilityLabel(label)
            Text(format(value.wrappedValue)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
                .contentTransition(.numericText(value: value.wrappedValue))
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .foregroundStyle(selected ? .black : .white.opacity(0.8))
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(selected ? AnyShapeStyle(SessionStyle.mint) : AnyShapeStyle(.white.opacity(0.07)), in: .capsule)
        }
        .buttonStyle(SessionPressStyle(scale: 0.94))
        .animation(motion(SessionMotion.snap), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Placing a block's fixed look-at point: touch the video, drag to refine, lift to set it.
struct ShotTargetPicker: View {
    let point: CGPoint?
    let tint: Color
    let onSet: (CGPoint) -> Void
    @State private var dragging: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let shown = dragging ?? point
            ZStack {
                Color.black.opacity(0.18).contentShape(.rect)
                if let shown {
                    ZStack {
                        Circle().strokeBorder(tint, lineWidth: 2).frame(width: 44, height: 44)
                        Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                    }
                    .position(x: shown.x * size.width, y: shown.y * size.height)
                    .transition(.scale.combined(with: .opacity))
                }
                Text("Touch where the camera should look")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14)
                    .opacity(dragging == nil ? 1 : 0)
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                dragging = CGPoint(x: min(1, max(0, value.location.x / max(1, size.width))),
                                   y: min(1, max(0, value.location.y / max(1, size.height))))
            }.onEnded { _ in
                if let dragging { onSet(dragging) }
                dragging = nil
            })
            .sensoryFeedback(.impact(weight: .light), trigger: dragging == nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touch the video where the camera should look")
        .accessibilityAction { onSet(CGPoint(x: 0.5, y: 0.5)) }
        .accessibilityIdentifier("shot-camera-target")
    }
}
