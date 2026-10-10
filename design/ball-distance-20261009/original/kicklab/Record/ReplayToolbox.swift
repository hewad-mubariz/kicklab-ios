import SwiftUI

enum ReplayTool: String, Identifiable {
    case counter = "Counter", timer = "Timer", ball = "Ball", effects = "Effects", graph = "Graph"
    var id: String { rawValue }
}

/// The Customize panel. Tools open in place, like a tray: the panel's height glides to fit
/// the next page while the old content blurs away and the new one settles in, so the video
/// stays in view and every pick applies live. Only the counter keeps its own canvas editor.
struct ReplayToolbox: View {
    @Binding var counter: ExportOverlayItem
    @Binding var edit: SessionEditState
    @Binding var showTime: Bool
    @Binding var showGraph: Bool
    @Binding var motionStyle: MotionStyle
    let motionSnapshot: MotionStyleSnapshot
    let sourceAspect: CGFloat
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    @Binding var page: ReplayTool?
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var ballKicks: [BallSkin: Int] = [:]
    /// The pick shows at once; the video takes the new ball once the pick moment has played,
    /// so redrawing the clip never steals frames from the flight.
    @State private var pendingBall: BallSkin?
    @State private var applyBall: Task<Void, Never>?
    private var shownBall: BallSkin { pendingBall ?? edit.ballSkin }
    @State private var effectKicks: [BallStyle: Int] = [:]
    /// The tray's height, measured from the page being shown and animated on one spring.
    @State private var trayHeight: CGFloat = 0
    /// Into a tool or back out of it; the swap leans slightly that way.
    @State private var forward = true

    private let skins: [BallSkin] = [.original, .chrome, .arctic, .matrix, .stealth, .crimson,
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
        .onAppear { appeared = true }
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
            Button(action: onClose) {
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
            // Tiles land one after another while the glass is still settling.
            HStack(spacing: 9) {
                tile(.counter).sessionEntrance(appeared, order: 1, offset: 14, scale: 0.88)
                tile(.timer).sessionEntrance(appeared, order: 2, offset: 14, scale: 0.88)
                tile(.ball).sessionEntrance(appeared, order: 3, offset: 14, scale: 0.88)
            }
            HStack(spacing: 9) {
                tile(.effects).sessionEntrance(appeared, order: 3, offset: 14, scale: 0.88)
                tile(.graph).sessionEntrance(appeared, order: 4, offset: 14, scale: 0.88)
                backgroundsPreview.sessionEntrance(appeared, order: 5, offset: 14, scale: 0.88)
            }
        }
        .padding(.horizontal, 16)
    }

    private func tile(_ tool: ReplayTool) -> some View {
        Button { go(tool) } label: {
            VStack(spacing: 6) {
                preview(for: tool).frame(height: 52).accessibilityHidden(true)
                Text(tool.rawValue).font(.system(size: 11, weight: .medium))
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
            .accessibilityLabel(tool.rawValue)
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
            togglePage(title: "Show elapsed time", note: "Time appears in the playback readout.", isOn: $showTime) {
                TimerPreview()
            }
        case .graph:
            ReplayMotionPicker(style: $motionStyle, showGraph: $showGraph, snapshot: motionSnapshot,
                               sourceAspect: sourceAspect, isPlaying: isPlaying, onTogglePlayback: onTogglePlayback)
        case .counter: counterPage
        }
    }

    /// Styles apply live while the clip loops, so each touch move plays on the real footage.
    /// Placement is direct: tapping the counter on the video lets you drag, pinch and twist it.
    private var counterPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            CounterStyleGrid(item: $counter)
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

    /// Every ball at once, four to a row, so they can be compared and picked directly.
    private var ballPage: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 22) {
            ForEach(Array(skins.enumerated()), id: \.element) { index, skin in
                // The right-hand columns swing left, so no ball leaves the panel's edge.
                ballOption(skin, direction: index % 4 < 2 ? 1 : -1)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
        .onDisappear(perform: commitBall)
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
        guard let pendingBall else { return }
        edit.ballSkin = pendingBall
        self.pendingBall = nil
    }

    private func ballOption(_ skin: BallSkin, direction: CGFloat) -> some View {
        let selected = shownBall == skin
        return Button { pick(skin) } label: {
            VStack(spacing: 6) {
                BallPickSlot(skin: skin, selected: selected, picks: ballKicks[skin, default: 0],
                             size: 52, direction: direction)
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
