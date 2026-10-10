import SwiftUI

/// Focused controls inside the existing glass tray. Timing edits are drafts until Done;
/// the large video shows original source pixels while a frame is being selected.
struct ShotCameraPicker: View {
    @Binding var settings: ShotCameraSettings
    @Binding var original: Bool
    @Binding var spatialEdit: ShotCameraSpatialEdit?
    @Binding var reviewFrames: [Double]
    let hasBallTrack: Bool
    let strike: Double
    let time: Double
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    let onSeek: (Double) -> Void
    let source: URL?
    let frames: ShotSourceFrames
    let pathEnd: Double
    let onPicking: (Bool) -> Void
    @State private var selection: Selection?
    @State private var draft = ShotSourceRange(start: 0, end: 1)
    @State private var cursor = 0.0
    @State private var returnTime = 0.0
    @State private var selectedReview: Int?

    private enum Selection: Equatable { case moment, range, freeze, pathEnd, addFrame, updateFrame }
    private var range: ShotSourceRange { settings.range(for: settings.style, strike: strike, duration: frames.duration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection {
                frameEditor(selection)
            } else {
                effectHeader
                if let spatialEdit {
                    HStack {
                        Text(spatialEdit.title).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 4)
                        Button("Done") { self.spatialEdit = nil }
                            .accessibilityIdentifier("shot-target-done")
                    }
                    .buttonStyle(.glass)
                    Text("Touch the preview to position it. Pinch to adjust zoom.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                } else {
                    controls
                }
            }
        }
        .padding(.horizontal, 16)
        .font(.system(size: 12))
        .sensoryFeedback(.selection, trigger: settings.style)
        .onDisappear { onPicking(false); spatialEdit = nil }
    }

    private var effectHeader: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ShotCameraStyle.allCases) { option in
                    Button {
                        spatialEdit = nil; original = false; settings.style = option
                    } label: {
                        Label(option.title, systemImage: settings.style == option ? "checkmark" : option.symbol)
                    }
                    .accessibilityIdentifier("shot-camera-" + option.rawValue)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: settings.style.symbol).foregroundStyle(SessionStyle.mint)
                    Text(settings.style.title).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.85)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .frame(minHeight: 36)
            }
            .accessibilityIdentifier("shot-camera-chooser")
            Spacer(minLength: 0)
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 24, height: 28)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("shot-camera-play")
            .disabled(spatialEdit != nil)
            Button { spatialEdit = nil; original.toggle() } label: {
                Text(original ? "Effect" : "Original").font(.system(size: 11, weight: .medium)).frame(minHeight: 28)
            }
            .tint(original ? SessionStyle.mint : .white)
            .accessibilityLabel(original ? "Show effect" : "Show original")
            .accessibilityIdentifier("shot-camera-original")
        }
        .buttonStyle(.glass)
    }

    @ViewBuilder private var controls: some View {
        switch settings.style {
        case .none:
            Text("Choose a camera effect above. Your video stays visible as you adjust it.")
                .foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
        case .follow:
            timingRange
            slider("Zoom", value: $settings.followZoom, range: 1...3, suffix: "×")
            choice("Follow", value: $settings.tightFollow, labels: ["Smooth", "Tight"])
            targetRow(manual: settings.followTarget != nil, edit: .follow) { settings.followTarget = nil }
        case .impact:
            momentRow(label: "Impact frame", time: strike, confirmed: settings.strike != nil, selection: .moment)
            slider("Zoom", value: $settings.impactZoom, range: 1...3, suffix: "×")
            slider("Duration", value: $settings.impactDuration, range: 0.2...1.5, suffix: " s")
            choice("Motion", value: $settings.punchyImpact, labels: ["Soft", "Punchy"])
            targetRow(manual: settings.impactTarget != nil, edit: .impact) { settings.impactTarget = nil }
        case .ramp:
            timingRange
            HStack {
                Text("Slow motion").fontWeight(.medium)
                Spacer()
                ForEach([0.25, 0.5, 1.0], id: \.self) { rate in
                    chip(String(format: "%g×", rate), selected: settings.rampRate == rate,
                         id: "shot-ramp-rate-\(rate)") { settings.rampRate = rate }
                }
            }
            choice("Transition", value: $settings.smoothRamp, labels: ["Instant", "Smooth"])
        case .tilt:
            momentRow(label: "Impact frame", time: strike, confirmed: settings.strike != nil, selection: .moment)
            slider("Angle", value: $settings.tiltAngle, range: 0...8, suffix: "°")
            choice("Direction", value: $settings.tiltRight, labels: ["Left", "Right"])
            slider("Settle time", value: $settings.tiltDuration, range: 0.2...1.5, suffix: " s")
        case .lens:
            timingRange
            slider("Magnification", value: $settings.lensZoom, range: 1.5...6, suffix: "×")
            HStack {
                Text("Lens size").fontWeight(.medium); Spacer()
                ForEach(ShotLensSize.allCases, id: \.self) { size in
                    chip(size.rawValue, selected: settings.lensSize == size, id: "shot-lens-size-\(size.rawValue)") { settings.lensSize = size }
                }
            }
            HStack(spacing: 8) {
                editButton("Inspect area", symbol: "scope", edit: .lensArea)
                editButton("Lens position", symbol: "arrow.up.and.down.and.arrow.left.and.right", edit: .lensPosition)
            }
            if settings.lensTarget != nil {
                Button("Reset inspection area to ball") { settings.lensTarget = nil }.font(.system(size: 11))
            }
        case .freeze:
            momentRow(label: "Freeze frame", time: settings.freezeFrame ?? strike,
                      confirmed: settings.freezeFrame != nil, selection: .freeze)
            slider("Hold", value: $settings.freezeHold, range: 0.2...3, suffix: " s")
            HStack {
                Toggle("Show path", isOn: $settings.showPath).accessibilityIdentifier("shot-freeze-path")
                Toggle("Direction", isOn: $settings.showDirection).accessibilityIdentifier("shot-freeze-direction")
            }
            .toggleStyle(.button).tint(SessionStyle.mint).font(.system(size: 11, weight: .medium))
            momentRow(label: "Path ends", time: settings.pathEnd ?? pathEnd, confirmed: settings.pathEnd != nil, selection: .pathEnd)
        case .split:
            timingRange
            slider("Detail zoom", value: $settings.splitZoom, range: 1...3, suffix: "×")
            choice("Layout", value: $settings.stackedSplit, labels: ["Side by side", "Stacked"])
            slider("Wide panel", value: $settings.splitBalance, range: 0.25...0.75, suffix: "%", multiplier: 100)
            targetRow(manual: settings.followTarget != nil, edit: .follow) { settings.followTarget = nil }
        case .frames:
            Text("Choose frames to inspect. These cards are for review and aren’t added to the saved video.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            if !reviewFrames.isEmpty {
                ShotCameraFilmstrip(source: source, times: reviewFrames, time: time, strike: strike) { stamp in
                    selectedReview = reviewFrames.firstIndex(of: stamp); onSeek(stamp)
                }
            }
            HStack(spacing: 8) {
                Button("Add frame") { begin(.addFrame) }.accessibilityIdentifier("shot-frame-add")
                    .disabled(frames.isEmpty || reviewFrames.count >= 6)
                Button("Update") { begin(.updateFrame) }.accessibilityIdentifier("shot-frame-update")
                    .disabled(frames.isEmpty || selectedReview == nil)
                Button("Remove") {
                    if let i = selectedReview, reviewFrames.indices.contains(i) { reviewFrames.remove(at: i) }
                    selectedReview = nil
                }.accessibilityIdentifier("shot-frame-remove").disabled(selectedReview == nil)
            }.buttonStyle(.glass).font(.system(size: 11, weight: .medium))
        }
        if settings.style.needsBall && !hasBallTrack && !settings.hasManualTarget {
            Text("No ball track here. Choose an area in the preview to use a fixed crop.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
        }
    }

    private var timingRange: some View {
        Button { begin(.range) } label: {
            HStack(spacing: 10) {
                Image(systemName: "timeline.selection").foregroundStyle(SessionStyle.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.style == .ramp ? "Slow-motion range" : "Visible range").font(.system(size: 11, weight: .medium))
                    Text(ShotSourceFrames.label(range.start) + " – " + ShotSourceFrames.label(range.end))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.65))
                        .accessibilityIdentifier("shot-range-time")
                }
                Spacer()
                Text("Edit").font(.system(size: 11, weight: .semibold))
            }
            .padding(10).background(.white.opacity(0.045), in: .rect(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(frames.isEmpty).accessibilityIdentifier("shot-edit-range")
    }
    private func momentRow(label: String, time: Double, confirmed: Bool, selection: Selection) -> some View {
        HStack(spacing: 8) {
            Button { begin(selection) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "film").foregroundStyle(SessionStyle.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label + (confirmed ? "" : " · Auto")).font(.system(size: 11, weight: .medium))
                        Text(ShotSourceFrames.label(time)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.65))
                            .accessibilityIdentifier("shot-moment-time-\(selection == .moment ? "impact" : selection == .freeze ? "freeze" : "path")")
                    }
                    Spacer()
                    Text("Choose").font(.system(size: 11, weight: .semibold))
                }.padding(10).background(.white.opacity(0.045), in: .rect(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(frames.isEmpty).accessibilityIdentifier("shot-edit-\(selection == .moment ? "moment" : selection == .freeze ? "freeze" : "path-end")")
            if confirmed {
                Button("Auto") {
                    if selection == .moment { settings.strike = nil }
                    if selection == .freeze { settings.freezeFrame = nil }
                    if selection == .pathEnd { settings.pathEnd = nil }
                }.buttonStyle(.glass).font(.system(size: 11)).accessibilityIdentifier("shot-camera-auto-strike")
            }
        }
    }
    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, multiplier: Double = 1) -> some View {
        HStack(spacing: 10) {
            Text(label).fontWeight(.medium).frame(minWidth: 72, alignment: .leading)
            Slider(value: value, in: range).tint(SessionStyle.mint).accessibilityLabel(label)
                .accessibilityIdentifier("shot-control-" + label.lowercased().replacingOccurrences(of: " ", with: "-"))
            Text(String(format: multiplier == 100 || suffix == "°" ? "%.0f" : "%.2f", value.wrappedValue * multiplier) + suffix)
                .font(.system(size: 11, weight: .medium)).monospacedDigit().frame(minWidth: 42, alignment: .trailing)
        }
    }
    private func choice(_ label: String, value: Binding<Bool>, labels: [String]) -> some View {
        HStack {
            Text(label).fontWeight(.medium); Spacer()
            chip(labels[0], selected: !value.wrappedValue, id: "shot-choice-" + labels[0]) { value.wrappedValue = false }
            chip(labels[1], selected: value.wrappedValue, id: "shot-choice-" + labels[1]) { value.wrappedValue = true }
        }
    }
    private func chip(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.75))
                .padding(.horizontal, 10).frame(minHeight: 34)
                .background(selected ? SessionStyle.mint.opacity(0.12) : .white.opacity(0.045), in: .capsule)
                .overlay { Capsule().strokeBorder(selected ? SessionStyle.mint.opacity(0.7) : .white.opacity(0.08), lineWidth: 1) }
        }.buttonStyle(SessionPressStyle(scale: 0.96)).accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityIdentifier(id)
    }
    private func targetRow(manual: Bool, edit: ShotCameraSpatialEdit, reset: @escaping () -> Void) -> some View {
        HStack {
            chip("Auto ball", selected: !manual, id: "shot-target-auto", action: reset)
            Spacer()
            editButton(manual ? "Adjust crop" : "Set target", symbol: "viewfinder", edit: edit)
        }
    }
    private func editButton(_ title: String, symbol: String, edit: ShotCameraSpatialEdit) -> some View {
        Button { original = false; spatialEdit = edit } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.glass).font(.system(size: 11, weight: .medium))
            .accessibilityIdentifier("shot-target-" + edit.rawValue)
    }
    private func begin(_ selection: Selection) {
        returnTime = time; self.selection = selection
        draft = ShotSourceRange(start: frames.nearest(range.start), end: frames.nearest(range.end))
        if draft.start >= draft.end { draft.start = frames.adjacent(to: draft.end, by: -1) }
        switch selection {
        case .moment: cursor = frames.nearest(strike)
        case .range: cursor = draft.start
        case .freeze: cursor = frames.nearest(settings.freezeFrame ?? strike)
        case .pathEnd:
            let minimum = settings.freezeFrame ?? strike
            cursor = frames.nearest(max(minimum, settings.pathEnd ?? pathEnd))
            if cursor < minimum { cursor = frames.adjacent(to: cursor, by: 1) }
        case .addFrame: cursor = frames.nearest(time)
        case .updateFrame: cursor = frames.nearest(selectedReview.flatMap { reviewFrames.indices.contains($0) ? reviewFrames[$0] : nil } ?? time)
        }
        onPicking(true); onSeek(cursor)
    }
    private func finish(_ commit: Bool) {
        if commit, let selection {
            switch selection {
            case .moment: settings.strike = cursor
            case .range: settings.ranges[settings.style] = draft
            case .freeze: settings.freezeFrame = cursor
            case .pathEnd: settings.pathEnd = max(settings.freezeFrame ?? strike, cursor)
            case .addFrame:
                if !reviewFrames.contains(cursor) { reviewFrames.append(cursor); reviewFrames.sort() }
                selectedReview = reviewFrames.firstIndex(of: cursor)
            case .updateFrame:
                if let i = selectedReview, reviewFrames.indices.contains(i) { reviewFrames[i] = cursor; reviewFrames = Array(Set(reviewFrames)).sorted(); selectedReview = reviewFrames.firstIndex(of: cursor) }
            }
        }
        selection = nil; onPicking(false); onSeek(commit ? cursor : returnTime)
    }
    private func frameEditor(_ selection: Selection) -> some View {
        ShotSourceFramePicker(source: source, frames: frames, title: selection == .range ? "Choose a range" : selection == .pathEnd ? "Choose path end" : "Choose a frame",
                              cursor: $cursor, range: selection == .range ? $draft : nil,
                              minimum: selection == .pathEnd ? settings.freezeFrame ?? strike : 0,
                              onSeek: onSeek, onCancel: { finish(false) }, onDone: { finish(true) })
    }
}
