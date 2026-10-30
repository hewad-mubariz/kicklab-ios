import SwiftUI

enum ReplayTool: String, Identifiable {
    case counter = "Counter", timer = "Timer", ball = "Ball", effects = "Effects", graph = "Graph", sound = "Sound"
    var id: String { rawValue }
    var requiresPro: Bool { self != .counter && self != .timer }
}

/// The Customize panel. Tools open in place, like a tray: the panel's height glides to fit
/// the next page while the old content blurs away and the new one settles in, so the video
/// stays in view and every pick applies live. Only the counter keeps its own canvas editor.
struct ReplayToolbox: View {
    @Binding var counter: ExportOverlayItem
    @Binding var edit: SessionEditState
    @Binding var showTime: Bool
    @Binding var showGraph: Bool
    @Binding var includeGraph: Bool
    @Binding var motionStyle: MotionStyle
    let motionSnapshot: MotionStyleSnapshot
    let sourceAspect: CGFloat
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    @Binding var page: ReplayTool?
    let onClose: () -> Void
    var showsTouchTools = true
    var isPro = false
    var onUnlockTool: (ReplayTool) -> Void = { _ in }
    /// Sorted touch times of the clip: the index space of per-touch balls. Empty hides those tools.
    var touchTimes: [Double] = []
    var currentTime: Double = 0
    /// Holds the clip at a moment, paused, so a pick is seen on that frame.
    var onSeek: (Double) -> Void = { _ in }
    /// Plays a short run through a ball change.
    var onPreviewMoment: (Double) -> Void = { _ in }
    var onPreviewSound: (ReplaySound) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var ballKicks: [BallSkin: Int] = [:]
    /// The pick shows at once; the video takes the new ball once the pick moment has played,
    /// so redrawing the clip never steals frames from the flight.
    @State private var pendingBall: BallSkin?
    @State private var applyBall: Task<Void, Never>?
    /// Per-touch mode: picks go to the chosen touch instead of the whole clip.
    @State private var perTouch = false
    @State private var selectedTouch = 0
    private var selectedBall: BallSkin { perTouch ? edit.ballSkin(forTouch: selectedTouch) : edit.ballSkin }
    private var shownBall: BallSkin { pendingBall ?? selectedBall }
    @State private var effectKicks: [BallStyle: Int] = [:]
    /// The tray's height, measured from the page being shown and animated on one spring.
    @State private var trayHeight: CGFloat = 0
    /// Into a tool or back out of it; the swap leans slightly that way.
    @State private var forward = true

    private let skins: [BallSkin] = [.original, .metal, .lava, .pearl, .volt,
                                     .chrome, .arctic, .matrix, .stealth, .crimson,
                                     .gold, .galaxy, .graffiti, .aurora, .classic]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ZStack(alignment: .top) {
                if let page {
                    pageContent(page)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit($0, for: page) }
                        .transition(swap)
                } else {
                    grid
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit($0, for: nil) }
                        .transition(swap)
                }
            }
            // The outgoing page never sizes the tray; it fades inside the new height.
            .frame(height: trayHeight > 0 ? trayHeight : nil, alignment: .top)
            // Content spans edge to edge; the inner content keeps the panel's 16 pt inset.
            // The negative padding leaves this view's bounds at the inset, so the clip is widened
            // back out to the panel's edge: otherwise controls drawn right at the inset, like
            // iOS switches, lose their last few points. Open above so a picked ball can fly over the header.
            .padding(.horizontal, -16)
            .mask { Rectangle().padding(.horizontal, -16).padding(.top, -400).padding(.bottom, -16) }
        }
        .padding(16).foregroundStyle(.white)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .onAppear {
            appeared = true
            perTouch = edit.hasBallChanges
            selectedTouch = nearestTouch(to: currentTime)
        }
        // The tap is the kick; the slot adds a thud when the ball lands.
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: shownBall)
        .sensoryFeedback(.selection, trigger: edit.style)
        .sensoryFeedback(.impact(weight: .light), trigger: page)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page != nil {
                Button { go(nil) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel("Back to tools")
                .accessibilityIdentifier("replay-tools-back")
                .transition(.sessionPop(scale: 0.4))
            }
            // The title swaps with the content, so the old and new words never blend letter by letter.
            ZStack(alignment: .leading) {
                Text(page?.rawValue ?? "Customize replay").font(.system(size: 17, weight: .semibold))
                    .id(page?.rawValue ?? "tools")
                    .transition(swap)
            }
            .sessionEntrance(appeared, offset: 8)
            Spacer(minLength: 8)
            Button { commitBall(); onClose() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
            .accessibilityLabel("Close customization tools")
            .accessibilityIdentifier("replay-close-tools")
            .sessionEntrance(appeared, order: 1, offset: 0, scale: 0.5)
        }
    }

    /// The outgoing page blurs and fades fast; the next one settles in sharp just behind it,
    /// leaning a few points in the direction of travel.
    private var swap: AnyTransition {
        if reduceMotion { return .opacity }
        let lean: CGFloat = forward ? 14 : -14
        return .asymmetric(
            insertion: .modifier(active: TraySwap(hidden: true, lean: lean), identity: TraySwap(hidden: false, lean: lean))
                .animation(.smooth(duration: 0.3).delay(0.05)),
            removal: .modifier(active: TraySwap(hidden: true, lean: -lean * 0.6), identity: TraySwap(hidden: false, lean: 0))
                .animation(.easeOut(duration: 0.14)))
    }

    private func go(_ next: ReplayTool?) {
        if !isPro, let next, next.requiresPro {
            onUnlockTool(next)
            return
        }
        commitBall()
        forward = next != nil
        withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { page = next }
    }

    /// Only the page being shown sets the height; the first measurement lands without animation.
    private func fit(_ height: CGFloat, for key: ReplayTool?) {
        guard key == page, abs(height - trayHeight) > 0.5 else { return }
        if trayHeight == 0 { trayHeight = height; return }
        withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { trayHeight = height }
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(spacing: 9) {
            if !showsTouchTools {
                HStack(spacing: 9) {
                    tile(.ball).sessionEntrance(appeared, order: 1, offset: 14, scale: 0.88)
                    tile(.effects).sessionEntrance(appeared, order: 2, offset: 14, scale: 0.88)
                    tile(.timer).sessionEntrance(appeared, order: 3, offset: 14, scale: 0.88)
                }
            } else {
            // Tiles land one after another while the glass is still settling.
            HStack(spacing: 9) {
                tile(.counter).sessionEntrance(appeared, order: 1, offset: 14, scale: 0.88)
                tile(.timer).sessionEntrance(appeared, order: 2, offset: 14, scale: 0.88)
                tile(.ball).sessionEntrance(appeared, order: 3, offset: 14, scale: 0.88)
            }
            HStack(spacing: 9) {
                tile(.effects).sessionEntrance(appeared, order: 3, offset: 14, scale: 0.88)
                tile(.graph).sessionEntrance(appeared, order: 4, offset: 14, scale: 0.88)
                tile(.sound).sessionEntrance(appeared, order: 5, offset: 14, scale: 0.88)
                // First release: background replacement and its placeholder stay parked.
                // backgroundsPreview.sessionEntrance(appeared, order: 5, offset: 14, scale: 0.88)
            }
            }
        }
        .padding(.horizontal, 16)
    }

    private func tile(_ tool: ReplayTool) -> some View {
        Button { go(tool) } label: {
            VStack(spacing: 6) {
                preview(for: tool).frame(height: 52).accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(tool.rawValue).font(.system(size: 11, weight: .medium))
                    if !isPro && tool.requiresPro { ProBadge() }
                }
            }.padding(.horizontal, 10).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.035)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 17))
                .overlay {
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                }
                .contentShape(.rect(cornerRadius: 17))
        }.buttonStyle(SessionPressStyle(scale: 0.92))
            .accessibilityLabel(tool.rawValue + (!isPro && tool.requiresPro ? ", Pro" : ""))
            .accessibilityIdentifier("replay-tool-\(tool.rawValue.lowercased())")
    }

    @ViewBuilder
    private func preview(for tool: ReplayTool) -> some View {
        switch tool {
        case .counter:
            if let image = ExportOverlayRenderer.image(style: counter.style, time: 5 + CounterArt.previewAge(counter.style),
                counter: .init(count: 5, isTotal: false, age: CounterArt.previewAge(counter.style))) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Text("05").font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
            }
        case .timer:
            TimerPreview()
        case .ball:
            // Shows the ball you picked, so the tile doubles as the current setting.
            BallSkinPreview(skin: edit.ballSkin == .original ? .chrome : edit.ballSkin)
        case .effects:
            Image("replay-tool-effects-v2").resizable().scaledToFit()
        case .graph:
            MotionStyleGraph(style: motionStyle, snapshot: MotionStyleSample.preview(for: motionStyle))
                .padding(.horizontal, 2).padding(.vertical, 6)
        case .sound:
            // Shows the touch sound in use, so the tile doubles as the current setting.
            VStack(spacing: 4) {
                Image(systemName: edit.hasSounds ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 22)).foregroundStyle(edit.hasSounds ? SessionStyle.mint : .white)
                    .contentTransition(.symbolEffect(.replace))
                Text(edit.touchSound == .none ? "Off" : edit.touchSound.title)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.interpolate)
            }
        }
    }

    private var backgroundsPreview: some View {
        VStack(spacing: 6) {
            VStack(spacing: 4) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 23)).foregroundStyle(.white.opacity(0.3))
                Text("Coming soon").font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: .capsule)
            }.frame(height: 52)
            Text("Backgrounds").font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(.horizontal, 6).padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(.white.opacity(0.025), in: .rect(cornerRadius: 17))
            .foregroundStyle(.white.opacity(0.5))
            .accessibilityElement(children: .ignore).accessibilityLabel("Backgrounds, coming soon")
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageContent(_ tool: ReplayTool) -> some View {
        switch tool {
        case .ball: ballPage
        case .effects: effectsPage
        case .timer:
            togglePage(title: "Show elapsed time", note: "Include the timer in your replay and saved video.", isOn: $showTime) {
                TimerPreview()
            }
        case .graph:
            ReplayMotionPicker(style: $motionStyle, showGraph: $showGraph, includeGraph: $includeGraph, snapshot: motionSnapshot,
                               sourceAspect: sourceAspect, isPlaying: isPlaying, onTogglePlayback: onTogglePlayback, showsProBadges: !isPro)
        case .counter: counterPage
        case .sound: ReplaySoundPage(edit: $edit, onPreview: onPreviewSound)
        }
    }

    /// Styles apply live while the clip loops, so each touch move plays on the real footage.
    /// Placement is direct: tapping the counter on the video lets you drag, pinch and twist it.
    private var counterPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            CounterStyleGrid(item: $counter, showsProBadges: !isPro, onUnlock: { onUnlockTool(.counter) })
                .padding(.horizontal, 16)
            HStack(spacing: 10) {
                Image(systemName: "hand.draw").font(.system(size: 15)).foregroundStyle(SessionStyle.mint)
                Text("Tap the counter on the video to move, pinch or twist it.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text("Show").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
                Toggle("Show counter", isOn: $counter.enabled.animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)))
                    .labelsHidden().tint(SessionStyle.mint)
                    .accessibilityIdentifier("counter-show")
            }
            .padding(.horizontal, 16)
        }
    }

    private enum BallMode: String, CaseIterable { case single = "One ball", perTouch = "Per touch" }

    /// One ball: every ball at once, four to a row, so they can be compared and picked directly.
    /// Per touch: the touch strip chooses the touch, one row of balls picks its ball, and a
    /// row of moments decides how the change looks.
    private var ballPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !touchTimes.isEmpty {
                SessionSegments(options: BallMode.allCases, selection: modeBinding, title: { $0.rawValue },
                                identifier: { $0 == .single ? "ball-mode-single" : "ball-mode-touches" })
                    .padding(.horizontal, 16)
            }
            if perTouch {
                HStack(spacing: 8) {
                    caption("Ball per touch", symbol: "hand.point.up.left.fill")
                    Spacer(minLength: 4)
                    cycleMenu
                    Button("Clear") {
                        commitBall()
                        withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { edit.ballChanges = [:] }
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(edit.hasBallChanges ? 0.9 : 0.4))
                    .disabled(!edit.hasBallChanges)
                    .accessibilityIdentifier("ball-touches-clear")
                }
                .padding(.horizontal, 16)
                .transition(.sessionRise)
                BallTouchStrip(touchTimes: touchTimes, edit: edit, selected: $selectedTouch) { index in
                    commitBall()
                    withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { selectedTouch = index }
                    onSeek(holdTime(forTouch: index))
                }
                .transition(.sessionRise)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(skins.enumerated()), id: \.element) { index, skin in
                            // The first balls swing right, the rest left, so none leaves the panel.
                            ballOption(skin, direction: index < 2 ? 1 : -1).frame(width: 66)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 2)
                }
                .scrollClipDisabled()
                .transition(.sessionRise)
                caption("Change effect", symbol: "sparkle").padding(.horizontal, 16)
                    .transition(.sessionRise)
                ReplayChipRow(items: BallSwapEffect.allCases, selection: edit.swapEffect, title: \.title, symbol: \.symbol,
                              identifier: { "ball-swap-\($0.rawValue)" },
                              accessibilityLabel: { $0 == .none ? "No change effect" : "\($0.title) change effect" }) { effect in
                    withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { edit.swapEffect = effect }
                    onPreviewMoment(momentTime)
                }
                .transition(.sessionRise)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 22) {
                    ForEach(Array(skins.enumerated()), id: \.element) { index, skin in
                        // The right-hand columns swing left, so no ball leaves the panel's edge.
                        ballOption(skin, direction: index % 4 < 2 ? 1 : -1)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
                .transition(.sessionRise)
            }
        }
        .onDisappear { applyBall?.cancel(); applyBall = nil; pendingBall = nil }
    }

    private func caption(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(SessionStyle.mint)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var modeBinding: Binding<BallMode> {
        Binding(get: { perTouch ? .perTouch : .single }, set: { mode in
            commitBall()
            withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                perTouch = mode == .perTouch
                if !perTouch { edit.ballChanges = [:] }
            }
            if perTouch {
                selectedTouch = nearestTouch(to: currentTime)
                onSeek(holdTime(forTouch: selectedTouch))
            }
        })
    }

    /// Rotates the balls in use (or a bright default set) across the touches.
    private var cycleMenu: some View {
        Menu {
            ForEach([1, 2, 3, 5, 10], id: \.self) { every in
                Button(every == 1 ? "Every touch" : "Every \(every) touches") { cycle(every: every) }
            }
        } label: {
            Label("Cycle", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 28)
                .background(.white.opacity(0.1), in: .capsule)
        }
        .accessibilityIdentifier("ball-touches-cycle")
    }

    private func cycle(every: Int) {
        commitBall()
        var order = edit.ballsInOrder
        for extra in [BallSkin.volt, .lava, .chrome, .galaxy] where order.count < 4 && !order.contains(extra) {
            order.append(extra)
        }
        withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
            edit.cycleBalls(order, every: every, touchCount: touchTimes.count)
        }
    }

    private func nearestTouch(to time: Double) -> Int {
        guard !touchTimes.isEmpty else { return 0 }
        var best = 0
        for (index, touch) in touchTimes.enumerated() where abs(touch - time) < abs(touchTimes[best] - time) { best = index }
        return best
    }

    /// A frame just after the touch, once the change moment has cleared and the new ball is in flight.
    private func holdTime(forTouch index: Int) -> Double {
        guard touchTimes.indices.contains(index) else { return currentTime }
        let next = index + 1 < touchTimes.count ? touchTimes[index + 1] - 0.03 : .infinity
        return min(touchTimes[index] + 0.22, max(touchTimes[index], next))
    }

    /// The change at or after the chosen touch, or the touch itself when nothing changes there.
    private var momentTime: Double {
        let swaps = edit.ballSwaps(touchTimes: touchTimes)
        return swaps.first { $0.index >= selectedTouch }?.time ?? swaps.last?.time
            ?? (touchTimes.indices.contains(selectedTouch) ? touchTimes[selectedTouch] : currentTime)
    }

    /// The same ball as the touch before means no change at this touch.
    private func setBall(_ skin: BallSkin, forTouch index: Int) {
        let before = index == 0 ? edit.ballSkin : edit.ballSkin(forTouch: index - 1)
        edit.ballChanges[index] = skin == before ? nil : skin
    }

    private func pick(_ skin: BallSkin) {
        ballKicks[skin, default: 0] += 1
        withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { pendingBall = skin }
        applyBall?.cancel()
        applyBall = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            commitBall()
        }
    }

    private func commitBall() {
        applyBall?.cancel(); applyBall = nil
        guard page == .ball, let pendingBall else { return }
        if perTouch { setBall(pendingBall, forTouch: selectedTouch) } else { edit.ballSkin = pendingBall }
        self.pendingBall = nil
    }

    private func ballOption(_ skin: BallSkin, direction: CGFloat) -> some View {
        let selected = shownBall == skin
        return Button { pick(skin) } label: {
            VStack(spacing: 6) {
                BallPickSlot(skin: skin, selected: selected, picks: ballKicks[skin, default: 0],
                             size: 52, direction: direction)
                    .overlay(alignment: .topTrailing) {
                        if !isPro && skin != .original { ProBadge().offset(x: 5, y: -4) }
                    }
                Text(skin == .original ? "Original" : skin.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .accessibilityLabel(skin == .original ? "Original ball" : skin.title)
        .accessibilityIdentifier("ball-picker-\(skin.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .zIndex(selected ? 1 : 0)
    }

    private var effectsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Every effect at once, four to a row, so the video keeps most of the screen.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 10) {
                ForEach(BallStyle.selectableCases) { style in effectOption(style) }
            }
            .padding(.horizontal, 16).padding(.top, 4)
            if edit.style != .none {
                HStack(spacing: 10) {
                    Text("Intensity").font(.system(size: 12, weight: .semibold))
                    SessionIntensitySlider(value: $edit.intensity)
                    Text("\(Int((edit.intensity * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText(value: edit.intensity))
                        .frame(width: 38, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .transition(.sessionRise)
            }
        }
    }

    private func effectOption(_ style: BallStyle) -> some View {
        let selected = edit.style == style
        return Button {
            effectKicks[style, default: 0] += 1
            withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { edit.style = style }
        } label: {
            VStack(spacing: 6) {
                EffectIcon(style: style, ball: edit.ballSkin)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(EffectIconRenderer.aspect, contentMode: .fit)
                    .background(selected ? SessionStyle.mint.opacity(0.1) : .white.opacity(0.04), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(.black, SessionStyle.mint).padding(4)
                                .transition(.sessionPop(scale: 0.2))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if !isPro && style != .none { ProBadge().padding(4) }
                    }
                    .sessionKick(effectKicks[style, default: 0], amount: 0.08)
                Text(style.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .accessibilityLabel(style == .none ? "No effect" : style.title)
        .accessibilityIdentifier("effect-picker-\(style.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func togglePage<Preview: View>(title: String, note: String, isOn: Binding<Bool>,
                                          @ViewBuilder preview: () -> Preview) -> some View {
        HStack(spacing: 14) {
            preview()
                .frame(width: 92, height: 52)
                .opacity(isOn.wrappedValue ? 1 : 0.25)
                .scaleEffect(isOn.wrappedValue || reduceMotion ? 1 : 0.92)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(title, isOn: isOn.animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)))
                    .font(.system(size: 14, weight: .semibold)).tint(SessionStyle.mint)
                Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }
}

private struct TimerPreview: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(SessionStyle.mint).frame(width: 5, height: 5)
            Text("00:12").font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(.black.opacity(0.24), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75) }
    }
}

/// Visible selection handles share the export transform; the video and output stay aligned.
struct CounterSelectionFrame: View {
    @Binding var placement: ExportOverlayPlacement
    let size: CGSize
    let onRemove: () -> Void
    @State private var initialScale: Double?

    var body: some View {
        let rect = placement.rect(in: size)
        ZStack {
            Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1).allowsHitTesting(false)
            ForEach(0..<4) { index in
                Circle().fill(.white).frame(width: 7, height: 7)
                    .position(x: index % 2 == 0 ? 0 : rect.width, y: index < 2 ? 0 : rect.height)
                    .allowsHitTesting(false)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black).frame(width: 25, height: 25).background(.white, in: .circle)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).position(x: 0, y: 0)
                .accessibilityLabel("Remove counter").accessibilityIdentifier("replay-remove-counter")
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                .frame(width: 25, height: 25).background(.white, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
                .gesture(DragGesture().onChanged { value in
                    if initialScale == nil { initialScale = placement.scale }
                    let delta = Double(value.translation.width + value.translation.height) / 240
                    placement = placement.transformed(scale: (initialScale ?? placement.scale) + delta, in: size)
                }.onEnded { _ in initialScale = nil })
                .position(x: rect.width, y: rect.height)
                .accessibilityLabel("Resize counter").accessibilityAddTraits(.allowsDirectInteraction)
        }
        .frame(width: rect.width, height: rect.height)
        .rotationEffect(.radians(placement.radians))
        .position(x: rect.midX, y: rect.midY)
    }
}

/// Page swap inside the tray: blurred, slightly smaller and leaning while hidden.
private struct TraySwap: ViewModifier {
    let hidden: Bool
    let lean: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(hidden ? 0.97 : 1, anchor: .top)
            .offset(x: hidden ? lean : 0)
            .blur(radius: hidden ? 10 : 0)
            .opacity(hidden ? 0 : 1)
    }
}
