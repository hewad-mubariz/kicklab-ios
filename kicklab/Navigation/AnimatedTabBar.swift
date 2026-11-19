import SwiftUI

/// Experiment: the app's own glass tab bar, so each icon can play a short animation
/// every time it is tapped, as Telegram's do. The native TabView still owns every
/// tab and keeps its state; only its bar is hidden (see `customTabBarSpace()`).
struct AnimatedTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill
    @State private var plays: [AppTab: Int] = [:]

    static let height: CGFloat = 62

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { tap(tab) } label: { item(tab) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(LocalizedStringKey(tab.title)))
                    .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }
        .padding(4)
        .frame(height: Self.height)
        .appGlass(in: Capsule())
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 14, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .frame(maxWidth: 520)
        .ignoresSafeArea(.keyboard)
        .onAppear { TabHaptics.prepare() }
        .accessibilityElement(children: .contain)
        #if DEBUG
        // Design review: replays every icon in turn, so screenshots can catch them moving.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--tab-icon-demo") else { return }
            while !Task.isCancelled {
                for tab in AppTab.allCases where tab != .home {
                    plays[tab, default: 0] += 1
                    try? await Task.sleep(for: .seconds(1.3))
                }
            }
        }
        #endif
    }

    private func item(_ tab: AppTab) -> some View {
        let selected = selection == tab
        let play = reduceMotion ? 0 : plays[tab, default: 0]
        return VStack(spacing: 3) {
            TabGlyph(tab: tab, selected: selected, play: play)
                .frame(width: 30, height: 26)
            // One weight for both states, so a long label like Leaderboard never
            // changes width (and shrinks to fit) as it is selected or left.
            Text(LocalizedStringKey(tab.title))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(selected ? TrainingHomeStyle.accent(scheme) : TrainingHomeStyle.ink(scheme).opacity(0.82))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if selected {
                Capsule()
                    .fill(TrainingHomeStyle.accent(scheme).opacity(scheme == .dark ? 0.16 : 0.13))
                    .matchedGeometryEffect(id: "pill", in: pill)
            }
        }
        .contentShape(Capsule())
    }

    private func tap(_ tab: AppTab) {
        if selection != tab {
            TabHaptics.tabChanged()
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) { selection = tab }
        }
        // Like Telegram, the icon plays on every tap, including the open tab.
        plays[tab, default: 0] += 1
    }
}

extension View {
    /// Hides the native tab bar for this tab and keeps room for `AnimatedTabBar`.
    func customTabBarSpace() -> some View {
        toolbar(.hidden, for: .tabBar)
            .safeAreaPadding(.bottom, AnimatedTabBar.height + 8)
    }
}

// MARK: - Icons

private struct TabGlyph: View {
    let tab: AppTab
    let selected: Bool
    let play: Int

    var body: some View {
        switch tab {
        case .home:
            Image(systemName: selected ? "house.fill" : "house")
                .font(.system(size: 20, weight: .medium))
                .symbolEffect(.bounce.down, value: play)
        case .learn: BootGlyph(selected: selected, play: play)
        case .challenges: StopwatchGlyph(selected: selected, play: play)
        case .wallGame: WallGlyph(selected: selected, play: play)
        case .leaderboard: TrophyGlyph(selected: selected, play: play)
        }
    }
}

/// The wall: on tap a ball is kicked at three tiles in turn, and each lights up when hit.
private struct WallGlyph: View {
    let selected: Bool
    let play: Int
    @Environment(\.colorScheme) private var scheme

    private struct Hits {
        var first = 0.0
        var second = 0.0
        var third = 0.0
        var ball = WallGlyph.launch
        var shown = 0.0
    }

    private static let tile: CGFloat = 7
    private static let gap: CGFloat = 2
    private static let launch = CGPoint(x: 13, y: 26)
    /// The tiles hit, in order: top right, bottom left, top middle.
    private static let order = [2, 3, 1]

    private static func centre(_ index: Int) -> CGPoint {
        CGPoint(x: 0.5 + tile / 2 + CGFloat(index % 3) * (tile + gap),
                y: 5 + tile / 2 + CGFloat(index / 3) * (tile + gap))
    }

    var body: some View {
        KeyframeAnimator(initialValue: Hits(), trigger: play) { hits in
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    let flash = flash(index, hits)
                    Group {
                        if selected {
                            RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                        } else {
                            RoundedRectangle(cornerRadius: 1.8, style: .continuous).strokeBorder(lineWidth: 1.4)
                        }
                    }
                    .frame(width: Self.tile, height: Self.tile)
                    .overlay {
                        RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                            .fill(flashColor).opacity(flash)
                    }
                    .scaleEffect(1 + 0.4 * flash)
                    .position(Self.centre(index))
                }
                Circle().frame(width: 4, height: 4)
                    .position(hits.ball)
                    .opacity(hits.shown)
            }
            .frame(width: 26, height: 26)
        } keyframes: { _ in
            KeyframeTrack(\.ball) {
                MoveKeyframe(Self.launch)
                LinearKeyframe(Self.centre(Self.order[0]), duration: 0.14)
                MoveKeyframe(Self.launch)
                LinearKeyframe(Self.launch, duration: 0.07)
                LinearKeyframe(Self.centre(Self.order[1]), duration: 0.13)
                MoveKeyframe(Self.launch)
                LinearKeyframe(Self.launch, duration: 0.07)
                LinearKeyframe(Self.centre(Self.order[2]), duration: 0.15)
            }
            KeyframeTrack(\.shown) {
                MoveKeyframe(1)
                LinearKeyframe(1, duration: 0.56)
                LinearKeyframe(0, duration: 0.04)
            }
            KeyframeTrack(\.first) {
                LinearKeyframe(0, duration: 0.14)
                LinearKeyframe(1, duration: 0.03)
                LinearKeyframe(0, duration: 0.32)
            }
            KeyframeTrack(\.second) {
                LinearKeyframe(0, duration: 0.34)
                LinearKeyframe(1, duration: 0.03)
                LinearKeyframe(0, duration: 0.32)
            }
            KeyframeTrack(\.third) {
                LinearKeyframe(0, duration: 0.56)
                LinearKeyframe(1, duration: 0.03)
                LinearKeyframe(0, duration: 0.36)
            }
        }
    }

    private func flash(_ index: Int, _ hits: Hits) -> Double {
        switch index {
        case Self.order[0]: hits.first
        case Self.order[1]: hits.second
        case Self.order[2]: hits.third
        default: 0
        }
    }

    private var flashColor: Color { scheme == .dark ? .white : TrainingHomeStyle.lime }
}

/// A boot with a ball above it: on tap the boot taps the ball up twice, a tiny
/// keepy-uppy, the skill the lessons teach.
private struct BootGlyph: View {
    let selected: Bool
    let play: Int

    static let line = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

    private struct Touch {
        var ball: CGFloat = 0
        var kick: Double = 0
    }

    var body: some View {
        KeyframeAnimator(initialValue: Touch(), trigger: play) { touch in
            ZStack {
                ZStack {
                    if selected {
                        IconPath(.boot).fill()
                        IconPath(.laces).stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                            .blendMode(.destinationOut)
                    } else {
                        IconPath(.boot).stroke(style: Self.line)
                        IconPath(.laces).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    }
                    IconPath(.studs).stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                .compositingGroup()
                .rotationEffect(.degrees(touch.kick), anchor: UnitPoint(x: 8 / 28, y: 21 / 28))
                ZStack {
                    if selected {
                        IconPath(.ball).fill()
                        IconPath(.panel).fill().blendMode(.destinationOut)
                    } else {
                        IconPath(.ball).stroke(style: Self.line)
                        IconPath(.panel).fill()
                    }
                }
                .compositingGroup()
                .offset(y: touch.ball)
            }
            .frame(width: 26, height: 26)
        } keyframes: { _ in
            KeyframeTrack(\.ball) {
                CubicKeyframe(4.6, duration: 0.15)
                CubicKeyframe(-3.4, duration: 0.2)
                CubicKeyframe(4.6, duration: 0.2)
                CubicKeyframe(-1.4, duration: 0.14)
                CubicKeyframe(0, duration: 0.14)
            }
            KeyframeTrack(\.kick) {
                CubicKeyframe(-9, duration: 0.15)
                CubicKeyframe(0, duration: 0.14)
                LinearKeyframe(0, duration: 0.25)
                CubicKeyframe(-7, duration: 0.1)
                CubicKeyframe(0, duration: 0.16)
            }
        }
    }
}

/// A stopwatch, juggled: on tap the button clicks, the hand sweeps a lap, and a ball
/// pops up off the crown twice, like keeping it up against the clock.
private struct StopwatchGlyph: View {
    let selected: Bool
    let play: Int

    private struct Lap {
        var hand: Double = 0
        var press: CGFloat = 0
        var ball: CGFloat = 0
        var shown = 0.0
    }

    var body: some View {
        KeyframeAnimator(initialValue: Lap(), trigger: play) { lap in
            ZStack {
                ZStack {
                    if selected {
                        IconPath(.watchFace).fill()
                        IconPath(.watchHand).stroke(style: BootGlyph.line)
                            .rotationEffect(.degrees(lap.hand), anchor: UnitPoint(x: 0.5, y: 16 / 28))
                            .blendMode(.destinationOut)
                    } else {
                        IconPath(.watchFace).stroke(style: BootGlyph.line)
                        IconPath(.watchHand).stroke(style: BootGlyph.line)
                            .rotationEffect(.degrees(lap.hand), anchor: UnitPoint(x: 0.5, y: 16 / 28))
                    }
                    IconPath(.watchSide).stroke(style: BootGlyph.line)
                }
                .compositingGroup()
                IconPath(.watchCrown).stroke(style: BootGlyph.line)
                    .offset(y: lap.press)
                Circle().frame(width: 4, height: 4)
                    .offset(y: -11.2 + lap.ball)
                    .opacity(lap.shown)
            }
            .frame(width: 26, height: 26)
        } keyframes: { _ in
            KeyframeTrack(\.hand) {
                MoveKeyframe(0)
                CubicKeyframe(360, duration: 0.8)
            }
            KeyframeTrack(\.press) {
                CubicKeyframe(1.2, duration: 0.06)
                CubicKeyframe(0, duration: 0.1)
                LinearKeyframe(0, duration: 0.2)
                CubicKeyframe(1, duration: 0.05)
                CubicKeyframe(0, duration: 0.1)
                LinearKeyframe(0, duration: 0.17)
                CubicKeyframe(0.8, duration: 0.05)
                CubicKeyframe(0, duration: 0.1)
            }
            KeyframeTrack(\.ball) {
                MoveKeyframe(0)
                CubicKeyframe(-7, duration: 0.2)
                CubicKeyframe(0, duration: 0.16)
                CubicKeyframe(-5, duration: 0.16)
                CubicKeyframe(0, duration: 0.15)
            }
            KeyframeTrack(\.shown) {
                MoveKeyframe(1)
                LinearKeyframe(1, duration: 0.66)
                LinearKeyframe(0, duration: 0.12)
            }
        }
    }
}

/// The trophy is raised and shaken like after a win: it lifts, wobbles side to side,
/// a shine sweeps across the cup, and a few sparkles finish it off.
private struct TrophyGlyph: View {
    let selected: Bool
    let play: Int
    @Environment(\.colorScheme) private var scheme

    private struct Lift {
        var rise: CGFloat = 0
        var tilt: Double = 0
        var size: CGFloat = 1
        var shine: CGFloat = -1
        var sparkle: Double = 1
    }

    var body: some View {
        KeyframeAnimator(initialValue: Lift(), trigger: play) { lift in
            ZStack {
                trophy
                    .overlay {
                        LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 7)
                            .rotationEffect(.degrees(20))
                            .offset(x: lift.shine * 14)
                            .mask(trophy)
                    }
                    .scaleEffect(lift.size, anchor: .bottom)
                    .rotationEffect(.degrees(lift.tilt), anchor: UnitPoint(x: 0.5, y: 0.92))
                    .offset(y: lift.rise)
                ZStack {
                    sparkle(at: CGPoint(x: 1, y: 5), size: 7, time: lift.sparkle, delay: 0.1)
                    sparkle(at: CGPoint(x: 25, y: 2), size: 8, time: lift.sparkle, delay: 0.2)
                    sparkle(at: CGPoint(x: 26, y: 15), size: 5.5, time: lift.sparkle, delay: 0.3)
                }
                .frame(width: 26, height: 26)
            }
        } keyframes: { _ in
            KeyframeTrack(\.rise) {
                CubicKeyframe(-3.5, duration: 0.12)
                LinearKeyframe(-3.5, duration: 0.42)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
            KeyframeTrack(\.size) {
                CubicKeyframe(1.14, duration: 0.12)
                LinearKeyframe(1.14, duration: 0.42)
                SpringKeyframe(1, duration: 0.3, spring: .bouncy)
            }
            KeyframeTrack(\.tilt) {
                LinearKeyframe(0, duration: 0.08)
                CubicKeyframe(-15, duration: 0.09)
                CubicKeyframe(13, duration: 0.1)
                CubicKeyframe(-10, duration: 0.1)
                CubicKeyframe(7, duration: 0.09)
                CubicKeyframe(-3, duration: 0.08)
                CubicKeyframe(0, duration: 0.1)
            }
            KeyframeTrack(\.shine) {
                MoveKeyframe(-1)
                LinearKeyframe(-1, duration: 0.14)
                CubicKeyframe(1.2, duration: 0.36)
            }
            KeyframeTrack(\.sparkle) {
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.9)
            }
        }
    }

    private var trophy: some View {
        Image(systemName: selected ? "trophy.fill" : "trophy")
            .font(.system(size: 20, weight: .medium))
    }

    private func sparkle(at point: CGPoint, size: CGFloat, time: Double, delay: Double) -> some View {
        let progress = (time - delay) / 0.5
        let shown = progress > 0 && progress < 1 ? sin(progress * .pi) : 0
        return SparkleShape()
            .fill(scheme == .dark ? TrainingHomeStyle.lime : TrainingHomeStyle.accent(scheme))
            .frame(width: size, height: size)
            .scaleEffect(0.3 + 0.9 * shown)
            .rotationEffect(.degrees(90 * progress))
            .opacity(shown)
            .position(point)
    }
}

/// The icons' drawings, on the 28-point grid they were designed on, scaled to the frame.
private struct IconPath: Shape {
    enum Kind { case boot, laces, studs, ball, panel, watchFace, watchHand, watchCrown, watchSide }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch kind {
        case .boot:
            p.move(to: pt(8.4, 9.6))
            p.addLine(to: pt(7.8, 19.4))
            p.addQuadCurve(to: pt(9.4, 21), control: pt(7.8, 21))
            p.addLine(to: pt(22.4, 21))
            p.addQuadCurve(to: pt(24.6, 18.9), control: pt(25, 21))
            p.addQuadCurve(to: pt(21.4, 16.5), control: pt(24.2, 17.2))
            p.addLine(to: pt(15.8, 15))
            p.addQuadCurve(to: pt(13.3, 12.4), control: pt(13.6, 14.3))
            p.addLine(to: pt(13, 9.6))
            p.closeSubpath()
        case .laces:
            p.move(to: pt(14.4, 13.2)); p.addLine(to: pt(16, 12.5))
            p.move(to: pt(15.4, 14.4)); p.addLine(to: pt(17, 13.7))
        case .studs:
            for x in [10, 14, 19, 22.4] as [CGFloat] { p.move(to: pt(x, 22.7)); p.addLine(to: pt(x, 23.5)) }
        case .ball:
            p.addEllipse(in: CGRect(x: 16.4, y: 3.1, width: 6.2, height: 6.2))
        case .panel:
            p.move(to: pt(19.5, 4.9))
            p.addLine(to: pt(20.7, 5.8)); p.addLine(to: pt(20.25, 7.2))
            p.addLine(to: pt(18.75, 7.2)); p.addLine(to: pt(18.3, 5.8))
            p.closeSubpath()
        case .watchFace:
            p.addEllipse(in: CGRect(x: 6, y: 8, width: 16, height: 16))
        case .watchHand:
            p.move(to: pt(14, 16)); p.addLine(to: pt(14, 11))
        case .watchCrown:
            p.move(to: pt(11.6, 4.4)); p.addLine(to: pt(16.4, 4.4))
            p.move(to: pt(14, 4.4)); p.addLine(to: pt(14, 8))
        case .watchSide:
            p.move(to: pt(20.2, 9.6)); p.addLine(to: pt(21.8, 8))
        }
        let scale = min(rect.width, rect.height) / 28
        return p.applying(CGAffineTransform(translationX: rect.midX - 14 * scale, y: rect.midY - 14 * scale)
            .scaledBy(x: scale, y: scale))
    }
}

/// A four-pointed star.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, w = r * 0.28
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
        path.closeSubpath()
        return path
    }
}
