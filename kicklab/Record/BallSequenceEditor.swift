import SwiftUI
import simd

/// Small ball renders for the touch dial and moment previews, drawn once per print off the main actor.
actor BallThumbnailStore {
    static let shared = BallThumbnailStore()
    private var images: [BallSkin: CGImage] = [:]
    private let pose = simd_quatf(angle: 1.89, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: 0.59, axis: SIMD3(1, 0, 0))

    func image(for skin: BallSkin) -> CGImage? {
        guard skin != .original else { return nil }
        if let hit = images[skin] { return hit }
        let rendered = BallSkinSphereRenderer.previewImage(skin: skin, time: 0, orientation: pose)
        if let rendered { images[skin] = rendered }
        return rendered
    }
}

/// A ball at thumbnail size; the original ball is the plain symbol.
struct BallThumbnail: View {
    let skin: BallSkin
    var size: CGFloat = 30
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if skin == .original {
                Image(systemName: "soccerball").font(.system(size: size * 0.72)).foregroundStyle(.white.opacity(0.8))
            } else if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .task(id: skin) {
            let requested = skin
            let rendered = await BallThumbnailStore.shared.image(for: requested)
            guard !Task.isCancelled else { return }
            withAnimation(SessionMotion.fade) { image = rendered }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Switch row

/// A setting inside the Customize tray: a lit symbol, a title, a line that explains the current
/// state, and an iOS switch. The row nudges when the app flips the switch for the person.
struct ToolSwitchRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let identifier: String
    var nudge = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? SessionStyle.background : SessionStyle.mint)
                .frame(width: 32, height: 32)
                .background(isOn ? SessionStyle.mint : SessionStyle.mint.opacity(0.14), in: .circle)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.66))
                    .contentTransition(.interpolate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn.animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)))
                .labelsHidden().tint(SessionStyle.mint)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.white.opacity(isOn ? 0.08 : 0.05), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isOn ? SessionStyle.mint.opacity(0.4) : .white.opacity(0.07), lineWidth: 0.75)
        }
        .sessionKick(nudge, amount: 0.035)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: isOn)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: detail)
        .padding(.horizontal, 16)
    }
}

// MARK: - Touch dial

/// Every counted touch on a dial. Swiping snaps touch to touch under the lens, holds the clip on
/// each one and ticks a haptic. Each touch shows its ball with a badge for its effect; the bar
/// under them is the runs of looks, each in its effect's colour and broken with a white dot where
/// a new run starts. The run under the lens is lit, because edits apply to all of it.
struct TouchDial: View {
    let touchTimes: [Double]
    let edit: SessionEditState
    @Binding var selected: Int
    /// A ball picked for the selected run that has not landed on the clip yet; the dial shows it at once.
    var pending: (run: Range<Int>, ball: BallSkin)? = nil
    let onSettle: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Int?

    private static let itemWidth: CGFloat = 52
    private static let lens: CGFloat = 46

    init(touchTimes: [Double], edit: SessionEditState, selected: Binding<Int>,
         pending: (run: Range<Int>, ball: BallSkin)? = nil, onSettle: @escaping (Int) -> Void) {
        self.touchTimes = touchTimes; self.edit = edit; _selected = selected
        self.pending = pending; self.onSettle = onSettle
        _position = State(initialValue: selected.wrappedValue)
    }

    private func look(_ index: Int) -> TouchLook {
        var look = edit.look(forTouch: index)
        if let pending, pending.run.contains(index) { look.ball = pending.ball }
        return look
    }

    var body: some View {
        let selectedRun = edit.run(containing: selected, touchCount: touchTimes.count)
        GeometryReader { geometry in
            let width = geometry.size.width
            // The lens's centre on screen. Distances are measured in screen space, because the
            // scroll view's own space leaves out the content margin that centres the first touch.
            let lensX = geometry.frame(in: .global).midX
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(touchTimes.indices, id: \.self) { index in
                            item(index, width: width, lensX: lensX, inSelectedRun: selectedRun.contains(index))
                                .frame(width: Self.itemWidth).id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(0, (width - Self.itemWidth) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
                .scrollPosition(id: $position, anchor: .center)
                // A freshly inserted lazy stack ignores its starting position; place it once laid out.
                .onAppear { DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) } }
            }
            // Touches fade toward the tray's edges, so the lens reads as the focus.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .top) { lens }
        }
        .frame(height: 80)
        .onChange(of: position) { _, value in
            guard let value, value != selected else { return }
            selected = value
            onSettle(value)
        }
        .onChange(of: selected) { _, value in
            guard position != value else { return }
            withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) { position = value }
        }
        .sensoryFeedback(.selection, trigger: position)
    }

    /// The fixed focus ring with a playhead notch, like the scrubber's thumb.
    private var lens: some View {
        ZStack {
            Circle()
                .fill(SessionStyle.mint.opacity(0.08))
            Circle()
                .strokeBorder(SessionStyle.mint, lineWidth: 1.6)
                .shadow(color: SessionStyle.mint.opacity(0.55), radius: 6)
            Capsule().fill(SessionStyle.mint).frame(width: 2.5, height: 7)
                .offset(y: -Self.lens / 2 - 5)
        }
        .frame(width: Self.lens, height: Self.lens)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func color(for look: TouchLook) -> Color {
        if look.effect != .none { return look.effect.tint }
        let accent = look.ball.accent
        return Color(red: accent.x, green: accent.y, blue: accent.z).opacity(look.ball == .original ? 0.35 : 1)
    }

    private func item(_ index: Int, width: CGFloat, lensX: CGFloat, inSelectedRun: Bool) -> some View {
        let look = look(index)
        let startsRun = index == 0 || edit.lookChanges[index] != nil
        let endsRun = index + 1 >= touchTimes.count || edit.lookChanges[index + 1] != nil
        let isSelected = index == selected
        // Changes ripple outward from the lens, so a recipe reads as one wave.
        let ripple = reduceMotion ? 0 : min(0.3, Double(abs(index - selected)) * 0.035)
        return Button {
            withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) { position = index }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    BallThumbnail(skin: look.ball, size: 34)
                        .id(look.ball)
                        .transition(.sessionPop(scale: 0.35))
                    // A ring bursts off the ball whenever its look changes.
                    Circle().strokeBorder(Self.color(for: look), lineWidth: 1.5)
                        .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? TouchLook(ball: .original, effect: .none) : look) { ring, wave in
                            ring.scaleEffect(1 + 0.7 * wave).opacity(wave > 0 && wave < 1 ? 1 - wave : 0)
                        } keyframes: { _ in
                            // Hidden while it waits for the ripple to reach it, then it bursts.
                            LinearKeyframe(0, duration: ripple)
                            LinearKeyframe(0.01, duration: 0.01)
                            CubicKeyframe(1, duration: 0.45)
                        }
                        .frame(width: 34, height: 34)
                    if look.effect != .none {
                        Image(systemName: look.effect.symbol)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(look.effect.tint)
                            .frame(width: 15, height: 15)
                            .background(.black.opacity(0.8), in: .circle)
                            .overlay { Circle().strokeBorder(look.effect.tint.opacity(0.6), lineWidth: 0.75) }
                            .offset(x: 14, y: 13)
                            .id(look.effect)
                            .transition(.sessionPop(scale: 0.2))
                    }
                }
                .frame(width: Self.lens, height: Self.lens)
                // Size and brightness fall away from the lens, read from the live scroll position.
                .visualEffect { content, proxy in
                    let distance = min(1, abs(proxy.frame(in: .global).midX - lensX) / max(1, width / 2))
                    return content.scaleEffect(1 - 0.34 * distance).opacity(1 - 0.5 * distance)
                }
                run(look: look, startsRun: startsRun, endsRun: endsRun, changes: startsRun && index > 0, lit: inSelectedRun)
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium)).monospacedDigit()
                    .foregroundStyle(isSelected ? SessionStyle.mint : .white.opacity(inSelectedRun ? 0.8 : 0.45))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion).delay(ripple), value: look)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: isSelected)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: inSelectedRun)
        .accessibilityLabel("Touch \(index + 1), \(look.ball == .original ? "original ball" : look.ball.title), \(look.effect == .none ? "no effect" : look.effect.title)")
        .accessibilityIdentifier("ball-touch-\(index + 1)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// One segment of a run; neighbouring items join into a continuous bar. The lit run is thicker.
    private func run(look: TouchLook, startsRun: Bool, endsRun: Bool, changes: Bool, lit: Bool) -> some View {
        let color = Self.color(for: look)
        return UnevenRoundedRectangle(topLeadingRadius: startsRun ? 2.5 : 0, bottomLeadingRadius: startsRun ? 2.5 : 0,
                                      bottomTrailingRadius: endsRun ? 2.5 : 0, topTrailingRadius: endsRun ? 2.5 : 0)
            .fill(color.opacity(lit ? 1 : 0.45))
            .frame(height: lit ? 5 : 3.5)
            .shadow(color: lit ? color.opacity(0.6) : .clear, radius: 4)
            .padding(.leading, startsRun ? 3 : 0).padding(.trailing, endsRun ? 3 : 0)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                if changes {
                    Circle().fill(.white).frame(width: 6, height: 6)
                        .shadow(color: color, radius: 3)
                        .transition(.sessionPop(scale: 0.2))
                }
            }
    }
}

// MARK: - Change moments

/// The change moments as tiles, each playing its own effect on a small ball with the same
/// renderer as the clip. The chosen tile keeps playing; a tap plays a tile once.
struct SwapMomentPicker: View {
    let selection: BallSwapEffect
    let from: BallSkin
    let to: BallSkin
    let onPick: (BallSwapEffect) -> Void
    @State private var plays: [BallSwapEffect: Int] = [:]
    @State private var images: [BallSkin: CGImage] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(BallSwapEffect.allCases) { effect in tile(effect).id(effect) }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .frame(height: 80)
        .task(id: [from, to]) {
            for skin in Set([from, to]) where images[skin] == nil {
                if let image = await BallThumbnailStore.shared.image(for: skin) { images[skin] = image }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tile(_ effect: BallSwapEffect) -> some View {
        let selected = effect == selection
        return Button {
            plays[effect, default: 0] += 1
            onPick(effect)
        } label: {
            VStack(spacing: 5) {
                SwapMomentPreview(effect: effect, from: from, to: to, fromImage: images[from], toImage: images[to],
                                  looping: selected, plays: plays[effect, default: 0])
                    .frame(width: 58, height: 58)
                    .background(selected ? SessionStyle.mint.opacity(0.1) : .white.opacity(0.05), in: .rect(cornerRadius: 15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15)
                            .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
                    }
                    .clipShape(.rect(cornerRadius: 15))
                    .sessionKick(plays[effect, default: 0], amount: 0.08)
                Text(effect.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 62)
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: selected)
        .accessibilityLabel(effect == .none ? "No change effect" : "\(effect.title) change effect")
        .accessibilityIdentifier("ball-swap-\(effect.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One moment on a small ball: the old ball, the change, the new ball. Static tiles hold the
/// middle of the moment, so each still reads as its effect.
struct SwapMomentPreview: View {
    let effect: BallSwapEffect
    let from: BallSkin
    let to: BallSkin
    let fromImage: CGImage?
    let toImage: CGImage?
    let looping: Bool
    let plays: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playStart: Date?

    /// Old ball, then the moment, then the new ball, then again.
    private static let cycle = 1.6
    private static let lead = 0.45

    private var animating: Bool { !reduceMotion && (looping || playStart != nil) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { context in
            Canvas { gc, size in draw(gc, size: size, at: phase(context.date)) }
        }
        .onChange(of: plays) { _, _ in
            guard !reduceMotion else { return }
            let started = Date.now
            playStart = started
            Task {
                try? await Task.sleep(for: .seconds(BallSwapEffect.duration + 0.4))
                if playStart == started { playStart = nil }
            }
        }
        .accessibilityHidden(true)
    }

    /// Seconds since the change; negative before it.
    private func phase(_ date: Date) -> Double {
        if let playStart { return date.timeIntervalSince(playStart) - 0.08 }
        if looping && !reduceMotion {
            return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle) - Self.lead
        }
        return BallSwapEffect.duration * 0.35
    }

    private func draw(_ gc: GraphicsContext, size: CGSize, at seconds: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width * 0.19
        let age = seconds / BallSwapEffect.duration
        let incoming = seconds >= 0
        let scale = incoming && age < 1 ? effect.ballScale(age: age) : 1
        let r = radius * scale
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let skin = incoming ? to : from
        if let image = incoming ? toImage : fromImage, skin != .original {
            gc.draw(Image(decorative: image, scale: 1), in: rect)
        } else {
            var symbol = gc.resolve(Image(systemName: "soccerball"))
            symbol.shading = .color(.white.opacity(0.85))
            gc.draw(symbol, in: rect)
        }
        guard effect != .none, incoming, age < 1 else { return }
        gc.withCGContext { cg in
            BallSwapRenderer.draw(in: cg, center: center, radius: radius, effect: effect, age: age,
                                  event: BallSwapEvent(index: 7, time: 0, from: from, to: to))
        }
    }
}

// MARK: - Sounds

/// A cue's real waveform as bars; bars past the cue's end stay as faint dots.
struct SoundWaveform: View {
    let sound: ReplaySound
    var bars = 12
    var color: Color = .white
    @State private var levels: [Float] = []
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (geometry.size.width - spacing * CGFloat(bars - 1)) / CGFloat(bars))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { index in
                    let level = CGFloat(levels.indices.contains(index) ? levels[index] : 0)
                    Capsule()
                        .fill(color.opacity(level > 0 ? 1 : 0.35))
                        .frame(width: barWidth,
                               height: max(2, geometry.size.height * level * (appeared || reduceMotion ? 1 : 0.12)))
                        // Bars rise one after another, like a level meter waking up.
                        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.62)
                                    .delay(Double(index) * 0.018), value: appeared)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: sound) {
            let requested = sound, count = bars
            let computed = await Task.detached(priority: .userInitiated) {
                ReplaySoundSynth.envelope(requested, bars: count)
            }.value
            guard !Task.isCancelled else { return }
            levels = computed
            appeared = true
        }
        .accessibilityHidden(true)
    }
}

/// A sound choice: its waveform, swept in mint while it plays.
struct SoundTile: View {
    let sound: ReplaySound
    let title: String
    let selected: Bool
    let identifier: String
    let accessibility: String
    let onPick: () -> Void
    @State private var sweep: CGFloat = 0
    @State private var lit: Double = 0
    @State private var plays = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            plays += 1
            onPick()
            playSweep()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if sound.isSilent {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.7))
                    } else {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                SoundWaveform(sound: sound, color: selected ? SessionStyle.mint.opacity(0.6) : .white.opacity(0.45))
                                SoundWaveform(sound: sound, color: selected ? SessionStyle.mint : .white)
                                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * sweep) }
                                    .opacity(lit)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 15)
                    }
                }
                .frame(width: 58, height: 58)
                .background(selected ? SessionStyle.mint.opacity(0.1) : .white.opacity(0.05), in: .rect(cornerRadius: 15))
                .overlay {
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
                }
                .sessionKick(plays, amount: 0.08)
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 62)
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: selected)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The playhead crosses the waveform in the cue's own time, then the light fades.
    private func playSweep() {
        guard !sound.isSilent, !reduceMotion else { return }
        let window = max(ReplaySoundSynth.duration(sound), 0.25)
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { sweep = 0; lit = 1 }
        let started = plays
        DispatchQueue.main.async {
            withAnimation(.linear(duration: window)) { sweep = 1 }
        }
        Task {
            try? await Task.sleep(for: .seconds(window + 0.2))
            guard plays == started else { return }
            withAnimation(.easeOut(duration: 0.35)) { lit = 0 }
        }
    }
}

/// The original sound, a sound for every touch and one for every ball change.
struct ReplaySoundPage: View {
    @Binding var edit: SessionEditState
    /// Set when picking a touch sound muted the original; choosing no touch sound brings it back.
    @Binding var autoMuted: Bool
    let onPreview: (ReplaySound) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolSwitchRow(symbol: edit.clipAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                          title: "Original sound", detail: originalDetail, isOn: originalBinding,
                          identifier: "sound-original", nudge: nudge)
            label("Touch sound", symbol: "hand.tap.fill")
            row(TouchSound.allCases, selection: edit.touchSound) { sound in
                SoundTile(sound: .touch(sound), title: sound.title, selected: sound == edit.touchSound,
                          identifier: "touch-sound-\(sound.rawValue)",
                          accessibility: sound == .none ? "No touch sound" : "\(sound.title) touch sound") {
                    pickTouch(sound)
                }
            }
            label("Ball change sound", symbol: "arrow.triangle.2.circlepath")
            // Auto follows the change effect; any other tile overrides it until Auto is picked again.
            row([nil] + BallSwapSound.allCases.map { Optional($0) }, selection: edit.swapSoundChoice) { choice in
                let sound = choice ?? edit.swapEffect.defaultSound
                SoundTile(sound: .swap(sound), title: choice?.title ?? "Auto", selected: choice == edit.swapSoundChoice,
                          identifier: "swap-sound-\(choice?.rawValue ?? "auto")",
                          accessibility: choice == nil ? "Auto ball change sound, \(sound.title), matches the change effect"
                              : choice == BallSwapSound.none ? "No ball change sound" : "\(sound.title) ball change sound") {
                    withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { edit.swapSoundChoice = choice }
                    onPreview(.swap(sound))
                }
                .overlay(alignment: .top) {
                    // Auto names the sound it is playing, so the pairing is never a guess.
                    if choice == nil, sound != .none {
                        Text(sound.title)
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(SessionStyle.background)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(SessionStyle.mint, in: .capsule)
                            .offset(y: -5)
                            .contentTransition(.interpolate)
                            .accessibilityHidden(true)
                    }
                }
            }
            if edit.hasLookChanges && edit.swapSoundChoice == nil && edit.swapEffect != .none {
                note("Auto plays \(edit.swapSound.title) with \(edit.swapEffect.title). Pick a sound to use your own.")
                    .accessibilityIdentifier("sound-auto-note")
            }
            if !edit.hasLookChanges {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(SessionStyle.mint)
                    Text("Add looks to hear the change sound.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .transition(.sessionRise)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sound-change-note")
            }
        }
        .padding(.top, 2)
    }

    private func note(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 12)).foregroundStyle(SessionStyle.mint)
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                .contentTransition(.interpolate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .transition(.sessionRise)
        .accessibilityElement(children: .combine)
    }

    private var originalDetail: String {
        if edit.clipAudio { return "Plays under your touch sounds" }
        return autoMuted ? "Muted for your touch sounds" : "Muted in replay and video"
    }

    private var originalBinding: Binding<Bool> {
        Binding(get: { edit.clipAudio }, set: { on in
            edit.clipAudio = on
            autoMuted = false
        })
    }

    /// A touch sound and the original audio compete, so the first touch sound mutes the original.
    private func pickTouch(_ sound: TouchSound) {
        let wasNone = edit.touchSound == .none
        withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
            edit.touchSound = sound
            if sound != .none, wasNone, edit.clipAudio {
                edit.clipAudio = false; autoMuted = true; nudge += 1
            } else if sound == .none, autoMuted {
                edit.clipAudio = true; autoMuted = false; nudge += 1
            }
        }
        onPreview(.touch(sound))
    }

    private func label(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(SessionStyle.mint)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16).padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func row<Item: Hashable, Tile: View>(_ items: [Item], selection: Item,
                                                @ViewBuilder tile: @escaping (Item) -> Tile) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in tile(item).id(item) }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .frame(height: 80)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
