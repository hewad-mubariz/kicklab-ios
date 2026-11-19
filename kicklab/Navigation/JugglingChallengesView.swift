import SwiftUI

/// The Challenges tab: a friend row, a group switcher, then one path of football kit per
/// group. Your ball sits on the next piece and hops on when that challenge is finished.
struct JugglingChallengesView: View {
    let personalBest: Int
    /// Opens the camera; nil is a normal session without a goal.
    let onStart: (Int?) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var progress = ChallengeProgress.shared
    @AppStorage("kicklab.challenges.group") private var groupRaw = JuggleChallenge.Group.streaks.rawValue
    @State private var selected: String?
    @State private var sheet: ChallengeSheet?
    @State private var hop: BallHop?
    @State private var filling: String?
    @State private var presses: [String: Int] = [:]
    @State private var kicks = 0
    @State private var ball: CGImage?
    @State private var mapWidth: CGFloat = 382
    @State private var mapTop: CGFloat = 0
    @State private var viewport: CGFloat = 800
    @State private var scroll = ScrollPosition(edge: .top)
    // Arrival: the line draws itself and each piece lands as it gets there.
    @State private var landed = 0
    @State private var arcProgress: CGFloat = 0
    @State private var ballIn = false
    @State private var headerIn = false
    @State private var arrivalRun = 0
    @State private var leftForSession = false
    private static let contentSpace = "challenge-content"
    private static let landStep = 0.22

    private var group: JuggleChallenge.Group {
        let stored = JuggleChallenge.Group(rawValue: groupRaw) ?? .streaks
        return JuggleChallenge.Group.paths.contains(stored) ? stored : .streaks
    }
    private var groupBinding: Binding<JuggleChallenge.Group> {
        Binding(get: { group }, set: { groupRaw = $0.rawValue })
    }
    private var challenges: [JuggleChallenge] { JuggleChallenge.path(group) }
    private func isDone(_ challenge: JuggleChallenge) -> Bool { progress.isDone(challenge, best: personalBest) }
    /// The ball's piece: the first unfinished challenge, or the badge at the end.
    private var ballSpot: String { challenges.first { !isDone($0) }?.id ?? PathLayout.trophyID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Challenges")
                    .font(TrainingHomeStyle.display(50, relativeTo: .largeTitle))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 10).padding(.bottom, 14)
                    .opacity(headerIn ? 1 : 0).offset(y: headerIn ? 0 : 8)
                    .animation(.easeOut(duration: 0.36), value: headerIn)
                ChallengeFriendRow(appeared: headerIn, onInvite: { sheet = .friends }, onFormat: { sheet = .invite($0.id) })
                ChallengeGroupSwitcher(selection: groupBinding, appeared: headerIn)
                    .padding(.top, 20)
                aboutRow.padding(.top, 12)
                map
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mapWidth = $0 }
            .padding(.horizontal, 16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.contentSpace))
        }
        .scrollIndicators(.hidden)
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in viewport = height }
        .onChange(of: selected) { _, id in reveal(id) }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .task { ball = (await HomeBallArt.loadClassic()).first }
        .onAppear {
            syncBall(animated: true)
            if hop != nil || leftForSession { showEverything() } else { playArrival(header: true) }
            leftForSession = false
        }
        .onChange(of: personalBest) { syncBall(animated: true) }
        .onChange(of: progress.marked) { syncBall(animated: true) }
        .onChange(of: groupRaw) {
            selected = nil; hop = nil; filling = nil
            syncBall(animated: false)
            playArrival(header: false)
        }
        .sheet(item: $sheet) { destination in
            Group {
                switch destination {
                case .rules(let id):
                    if let challenge = JuggleChallenge.with(id: id) {
                        ChallengeRulesSheet(challenge: challenge, best: personalBest, done: isDone(challenge),
                                            onTry: { sheet = nil; start(challenge) },
                                            onFriend: { sheet = .invite(challenge.id) },
                                            onMark: { progress.mark(challenge, done: true); sheet = nil })
                    }
                case .invite(let id):
                    if let challenge = JuggleChallenge.with(id: id) {
                        NavigationStack { ChallengeInviteSheet(challenge: challenge) }
                    }
                case .friends:
                    ChallengeFriendFormatsSheet()
                }
            }
            .preferredColorScheme(scheme)
        }
        .accessibilityIdentifier("challenges-screen")
    }

    private var aboutRow: some View {
        let done = challenges.filter { isDone($0) }.count
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(group.about)
                .font(.footnote)
                .foregroundStyle(TrainingHomeStyle.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("\(done) of \(challenges.count)")
                .font(.footnote.weight(.semibold)).monospacedDigit()
                .foregroundStyle(TrainingHomeStyle.accent(scheme))
                .contentTransition(.numericText())
        }
        .animation(.snappy, value: groupRaw)
    }

    // MARK: Path

    /// Laid out from a measured width (not a GeometryReader) so the scroll view can find each piece.
    private var map: some View {
        let layout = PathLayout(challenges: challenges, width: mapWidth)
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(.rect).onTapGesture { selected = nil }
            arcs(layout)
            ForEach(Array(challenges.enumerated()), id: \.element.id) { index, challenge in
                kit(challenge, index: index, layout: layout)
            }
            trophy(at: layout.trophy, index: challenges.count)
            ballLayer(layout)
            if let id = selected, let index = challenges.firstIndex(where: { $0.id == id }) {
                let challenge = challenges[index]
                ChallengeCupCard(challenge: challenge, best: personalBest, done: isDone(challenge),
                                 arrowX: layout.centres[index].x,
                                 onClose: { selected = nil },
                                 onTry: { start(challenge) },
                                 onFriend: { sheet = .invite(challenge.id) },
                                 onRules: { sheet = .rules(challenge.id) },
                                 onMark: { progress.mark(challenge, done: true); selected = nil })
                    .frame(width: mapWidth)
                    .offset(y: layout.centres[index].y + layout.sizes[index] / 2 + 34)
                    // The card grows out of the piece that was tapped.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.1, anchor: UnitPoint(x: layout.centres[index].x / max(1, mapWidth), y: 0)).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
                    .zIndex(5)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.74), value: selected)
        .frame(width: mapWidth, height: PathLayout.height(count: challenges.count), alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.contentSpace)).minY } action: { mapTop = $0 }
        .padding(.top, 4)
    }

    private func arcs(_ layout: PathLayout) -> some View {
        let upcoming = scheme == .dark ? Color(red: 0.23, green: 0.27, blue: 0.29) : Color(red: 0.76, green: 0.79, blue: 0.74)
        let stops = layout.centres.indices.map { layout.edge($0) } + [layout.trophyEdge]
        var reached: [ArcSegments.Segment] = [], ahead: [ArcSegments.Segment] = []
        for index in 1..<stops.count {
            let segment = ArcSegments.Segment(index: index - 1, from: stops[index - 1], to: stops[index])
            if isDone(challenges[index - 1]) { reached.append(segment) } else { ahead.append(segment) }
        }
        let style = StrokeStyle(lineWidth: 3.4, lineCap: .round, dash: [0.1, 10])
        let total = stops.count - 1
        return ZStack {
            ArcSegments(segments: ahead, total: total, progress: arcProgress).stroke(upcoming, style: style)
            ArcSegments(segments: reached, total: total, progress: arcProgress).stroke(TrainingHomeStyle.accent(scheme), style: style)
        }
        .allowsHitTesting(false)
    }

    private func kit(_ challenge: JuggleChallenge, index: Int, layout: PathLayout) -> some View {
        let done = isDone(challenge)
        let next = challenge.id == ballSpot
        let size = layout.sizes[index], centre = layout.centres[index]
        let isIn = landed > index
        let dimmed = selected != nil && selected != challenge.id
        return Group {
            if next && !reduceMotion && hop == nil {
                NextGlow(size: size)
                    .position(x: centre.x, y: centre.y + size * 0.44)
                    .opacity(isIn ? 1 : 0)
            }
            Button {
                presses[challenge.id, default: 0] += 1
                selected = selected == challenge.id ? nil : challenge.id
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    if filling == challenge.id {
                        FinishingKit(challenge: challenge, best: personalBest, size: size)
                    } else {
                        ChallengeKitView(challenge: challenge, best: personalBest,
                                         state: done ? .done : next ? .next : .open, size: size, lively: hop == nil)
                        if done { DoneCheck(size: size) }
                    }
                }
                .frame(width: size, height: size)
                .keyframeAnimator(initialValue: 1.0, trigger: presses[challenge.id, default: 0]) { content, scale in
                    content.scaleEffect(scale, anchor: .bottom)
                } keyframes: { _ in
                    LinearKeyframe(0.9, duration: 0.1)
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy(duration: 0.3, extraBounce: 0.25))
                }
                .scaleEffect(selected == challenge.id ? 1.06 : 1, anchor: .bottom)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(challenge.title))
            .accessibilityValue(done ? Text("Done") : Text(""))
            .accessibilityIdentifier("challenge-cup-\(challenge.id)")
            .position(centre)
            .opacity(isIn ? (dimmed ? 0.45 : 1) : 0)
            .scaleEffect(isIn ? 1 : 0.5, anchor: .bottom)
            .offset(y: isIn ? 0 : -22)

            Text(LocalizedStringKey(challenge.title))
                .font(.system(size: 13.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(done ? TrainingHomeStyle.muted(scheme) : TrainingHomeStyle.ink(scheme))
                .frame(width: 150)
                .fixedSize(horizontal: false, vertical: true)
                .position(x: centre.x, y: centre.y + size / 2 + 12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(isIn ? (dimmed ? 0.45 : 1) : 0)
        }
        .animation(.easeInOut(duration: 0.25), value: dimmed)
    }

    private func trophy(at centre: CGPoint, index: Int) -> some View {
        let left = challenges.filter { !isDone($0) }.count
        let won = left == 0
        let isIn = landed > index
        return Group {
            Image(systemName: "trophy.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(won ? TrainingHomeStyle.buttonInk : TrainingHomeStyle.muted(scheme))
                .frame(width: PathLayout.trophyRadius * 2, height: PathLayout.trophyRadius * 2)
                .background {
                    if won { Circle().fill(TrainingHomeStyle.lime) }
                    else { Circle().strokeBorder(TrainingHomeStyle.line(scheme), style: StrokeStyle(lineWidth: 2, dash: [5, 5])) }
                }
                .position(centre)
            VStack(spacing: 1) {
                Text("Badge").font(.system(size: 13.5, weight: .semibold))
                Group { won ? Text("Unlocked") : Text("\(left) to go") }
                    .font(.caption).foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            .frame(width: 150)
            .position(x: centre.x, y: centre.y + PathLayout.trophyRadius + 24)
        }
        .opacity(isIn ? 1 : 0)
        .scaleEffect(isIn ? 1 : 0.5)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("challenge-badge")
    }

    private func ballLayer(_ layout: PathLayout) -> some View {
        let rest = layout.rest(of: ballSpot)
        return TimelineView(.animation(minimumInterval: nil, paused: hop == nil)) { timeline in
            let flight = hop.map { $0.state(at: timeline.date, layout: layout) }
            ZStack(alignment: .topLeading) {
                if let flight {
                    Canvas { context, _ in
                        for dot in flight.trail {
                            let rect = CGRect(x: dot.point.x - 4.5, y: dot.point.y - 4.5, width: 9, height: 9)
                            context.fill(Path(ellipseIn: rect), with: .color(TrainingHomeStyle.lime.opacity(dot.alpha)))
                        }
                    }
                    .allowsHitTesting(false)
                }
                Button { kicks += 1 } label: {
                    PathBall(image: ball, kicks: kicks, bouncing: flight == nil && !reduceMotion && ballIn)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Your ball"))
                .accessibilityHint(Text("Kicks it up"))
                .accessibilityIdentifier("challenge-ball")
                .offset(y: ballIn ? 0 : -150)
                .opacity(ballIn ? 1 : 0)
                .position(flight?.point ?? rest)
            }
        }
    }

    // MARK: Actions

    /// Scrolls the tapped piece near the top so its card shows above the tab bar.
    private func reveal(_ id: String?) {
        guard let id, let index = challenges.firstIndex(where: { $0.id == id }) else { return }
        let layout = PathLayout(challenges: challenges, width: mapWidth)
        let pieceTop = mapTop + layout.centres[index].y - layout.sizes[index] / 2
        withAnimation(.smooth(duration: 0.35)) { scroll.scrollTo(y: max(0, pieceTop - viewport * 0.14)) }
    }

    private func start(_ challenge: JuggleChallenge) {
        selected = nil
        leftForSession = true
        onStart(challenge.cameraTarget(best: personalBest))
    }

    /// Friends pop in, the dotted line draws itself, each piece lands as the line reaches
    /// it, then the ball drops onto the next one. Runs on arriving at the tab and on a group change.
    private func playArrival(header: Bool) {
        guard !reduceMotion else { showEverything(); return }
        arrivalRun += 1
        let run = arrivalRun, count = challenges.count + 1
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) {
            landed = 0; arcProgress = 0; ballIn = false
            if header { headerIn = false }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard run == arrivalRun else { return }
            if header { headerIn = true }
            try? await Task.sleep(for: .milliseconds(header ? 300 : 60))
            guard run == arrivalRun else { return }
            withAnimation(.linear(duration: Double(count - 1) * Self.landStep)) { arcProgress = 1 }
            for index in 0..<count {
                guard run == arrivalRun else { return }
                withAnimation(.spring(response: 0.46, dampingFraction: 0.6)) { landed = index + 1 }
                try? await Task.sleep(for: .seconds(Self.landStep))
            }
            guard run == arrivalRun else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { ballIn = true }
        }
    }

    private func showEverything() {
        arrivalRun += 1
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) { landed = .max; arcProgress = 1; ballIn = true; headerIn = true }
    }

    /// Moves the ball to the next piece. When the piece it sat on has just been finished, that
    /// piece fills lime, the check stamps on, and the ball hops along the arc instead of jumping.
    private func syncBall(animated: Bool) {
        let target = ballSpot
        let previous = progress.ballSpot(for: group)
        progress.setBallSpot(target, for: group)
        guard animated, !reduceMotion, let previous, previous != target,
              let finished = JuggleChallenge.with(id: previous), finished.group == group, isDone(finished)
        else { return }
        showEverything()
        filling = previous
        let flight = BallHop(from: previous, to: target, start: .now)
        hop = flight
        Task {
            try? await Task.sleep(for: .seconds(BallHop.total + 0.15))
            if hop?.start == flight.start { hop = nil; filling = nil }
        }
    }
}

// MARK: - Model helpers

extension JuggleChallenge {
    var friendKind: FriendFormat? {
        if case .friend(let kind) = rule { return kind }
        return nil
    }
    var isFriend: Bool { friendKind != nil }
}

enum ChallengeSheet: Identifiable {
    case rules(String), invite(String), friends
    var id: String {
        switch self {
        case .rules(let id): "rules-\(id)"
        case .invite(let id): "invite-\(id)"
        case .friends: "friends"
        }
    }
}

// MARK: - Layout

nonisolated struct PathLayout {
    static let trophyID = "badge"
    static let trophyRadius: CGFloat = 44
    private static let top: CGFloat = 96
    private static let step: CGFloat = 166
    private static let ballRadius: CGFloat = 15

    let centres: [CGPoint]
    let sizes: [CGFloat]
    /// The top of each piece of kit, where the arcs meet and the ball rests.
    let tops: [CGPoint]
    let ids: [String]
    let trophy: CGPoint

    @MainActor init(challenges: [JuggleChallenge], width: CGFloat) {
        let centres = challenges.indices.map { index in
            CGPoint(x: (width * (index.isMultiple(of: 2) ? 0.28 : 0.72)).rounded(), y: Self.top + CGFloat(index) * Self.step)
        }
        let sizes = challenges.map { ($0.cupRadius * 2.2).rounded() }
        self.centres = centres
        self.sizes = sizes
        tops = challenges.indices.map { index in
            let anchor = challenges[index].kitTop, size = sizes[index]
            return CGPoint(x: centres[index].x + (anchor.x - 0.5) * size, y: centres[index].y + (anchor.y - 0.5) * size)
        }
        ids = challenges.map(\.id)
        trophy = CGPoint(x: (width / 2).rounded(), y: Self.top + CGFloat(challenges.count) * Self.step + 6)
    }

    static func height(count: Int) -> CGFloat { top + CGFloat(count) * step + 6 + trophyRadius + 110 }

    func edge(_ index: Int) -> CGPoint { CGPoint(x: tops[index].x, y: tops[index].y - 2) }
    var trophyEdge: CGPoint { CGPoint(x: trophy.x, y: trophy.y - Self.trophyRadius - 3) }

    /// The ball sits on top of its piece, so it flies just above the dotted arc.
    func rest(of id: String) -> CGPoint {
        if let index = ids.firstIndex(of: id) {
            return CGPoint(x: tops[index].x, y: tops[index].y - Self.ballRadius + 2)
        }
        return CGPoint(x: trophy.x, y: trophy.y - Self.trophyRadius - Self.ballRadius + 2)
    }

    static func control(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 50)
    }
}

/// Dotted arcs that draw themselves one after another as `progress` goes from 0 to 1.
struct ArcSegments: Shape {
    struct Segment { let index: Int; let from: CGPoint; let to: CGPoint }
    let segments: [Segment]
    let total: Int
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in segments {
            let share = min(1, max(0, progress * CGFloat(total) - CGFloat(segment.index)))
            guard share > 0 else { continue }
            var arc = Path()
            arc.move(to: segment.from)
            arc.addQuadCurve(to: segment.to, control: PathLayout.control(segment.from, segment.to))
            path.addPath(share < 1 ? arc.trimmedPath(from: 0, to: share) : arc)
        }
        return path
    }
}

/// The ball's flight from a finished piece to the next one, with a fading lime trail.
nonisolated struct BallHop {
    /// Waits for the piece to fill and the check to stamp on.
    static let delay = 1.05
    static let duration = 0.95
    static var total: Double { delay + duration }

    let from: String
    let to: String
    let start: Date

    struct Dot { let point: CGPoint; let alpha: Double }

    func state(at date: Date, layout: PathLayout) -> (point: CGPoint, trail: [Dot]) {
        let a = layout.rest(of: from), b = layout.rest(of: to)
        let c = PathLayout.control(a, b)
        func point(_ t: Double) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
        let elapsed = date.timeIntervalSince(start) - Self.delay
        let raw = max(0, min(1, elapsed / Self.duration))
        let eased = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2
        let trail: [Dot] = stride(from: 0.1, to: 0.95, by: 0.07).compactMap { t in
            // When the ball passed this point on the eased curve.
            let passed = t < 0.5 ? sqrt(t / 2) : 1 - sqrt((1 - t) / 2)
            let age = elapsed - passed * Self.duration
            guard age > 0, age < 0.75 else { return nil }
            return Dot(point: point(t), alpha: 0.9 * (1 - age / 0.75))
        }
        return (point(eased), trail)
    }
}

/// Finishing: the next-up piece fills lime from the bottom, the check stamps on and a ring
/// of lime dots bursts out. Plays once, when the piece appears in this state.
private struct FinishingKit: View {
    let challenge: JuggleChallenge
    let best: Int
    let size: CGFloat
    @State private var started = false

    struct Phase { var fill: CGFloat = 0; var check: CGFloat = 2.4; var checkOpacity: Double = 0; var burst: CGFloat = 0 }

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .keyframeAnimator(initialValue: Phase(), trigger: started) { _, phase in
                ZStack(alignment: .bottomTrailing) {
                    ChallengeKitView(challenge: challenge, best: best, state: .next, size: size, lively: false)
                    ChallengeKitView(challenge: challenge, best: best, state: .done, size: size, lively: false)
                        .modifier(FillMask(fill: phase.fill))
                    DoneCheck(size: size)
                        .scaleEffect(phase.check)
                        .rotationEffect(.degrees(Double(phase.check - 1) * -20))
                        .opacity(phase.checkOpacity)
                }
                .frame(width: size, height: size)
                .overlay {
                    if phase.burst > 0 && phase.burst < 1 {
                        ForEach(0..<10, id: \.self) { index in
                            let angle = Double(index) / 10 * 2 * .pi
                            Circle()
                                .fill(TrainingHomeStyle.lime)
                                .frame(width: 8, height: 8)
                                .shadow(color: TrainingHomeStyle.lime.opacity(0.8), radius: 4)
                                .scaleEffect(1 - 0.7 * phase.burst)
                                .offset(x: CGFloat(cos(angle)) * size * 0.55 * phase.burst,
                                        y: CGFloat(sin(angle)) * size * 0.55 * phase.burst)
                                .opacity(Double(1 - phase.burst))
                        }
                    }
                }
        } keyframes: { _ in
            KeyframeTrack(\.fill) {
                LinearKeyframe(0, duration: 0.2)
                CubicKeyframe(1, duration: 0.5)
            }
            KeyframeTrack(\.check) {
                LinearKeyframe(2.4, duration: 0.7)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy(duration: 0.35, extraBounce: 0.2))
            }
            KeyframeTrack(\.checkOpacity) {
                LinearKeyframe(0, duration: 0.7)
                LinearKeyframe(1, duration: 0.1)
            }
            KeyframeTrack(\.burst) {
                LinearKeyframe(0.001, duration: 0.7)
                LinearKeyframe(1, duration: 0.56, timingCurve: .easeOut)
            }
        }
        .onAppear { started = true }
    }
}

private struct FillMask: ViewModifier {
    let fill: CGFloat
    func body(content: Content) -> some View {
        content.mask(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle().frame(height: geo.size.height * fill).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

private struct DoneCheck: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(TrainingHomeStyle.lime)
            .frame(width: 21, height: 21)
            .background(TrainingHomeStyle.buttonInk, in: .circle)
            .overlay(Circle().stroke(TrainingHomeStyle.background(scheme), lineWidth: 2))
            .offset(x: -size * 0.04, y: -size * 0.06)
    }
}

/// A soft lime pool under the next piece that breathes.
private struct NextGlow: View {
    let size: CGFloat
    var body: some View {
        Ellipse()
            .fill(TrainingHomeStyle.lime)
            .frame(width: size * 0.72, height: size * 0.13)
            .blur(radius: 6)
            .keyframeAnimator(initialValue: 0.18, repeating: true) { content, value in
                content.opacity(value).scaleEffect(0.85 + value)
            } keyframes: { _ in
                CubicKeyframe(0.42, duration: 1.2)
                CubicKeyframe(0.18, duration: 1.2)
            }
            .allowsHitTesting(false)
    }
}

/// The group switcher: an iOS segmented track with a kit icon per group. The chosen group
/// opens to show its name and the thumb springs across to it.
private struct ChallengeGroupSwitcher: View {
    @Binding var selection: JuggleChallenge.Group
    let appeared: Bool
    @Namespace private var thumb
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(JuggleChallenge.Group.paths.enumerated()), id: \.element) { index, group in
                let on = group == selection
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { selection = group }
                } label: {
                    HStack(spacing: 6) {
                        ChallengeGroupGlyph(group: group)
                            .frame(width: 21, height: 21)
                            .foregroundStyle(on ? TrainingHomeStyle.accent(scheme) : TrainingHomeStyle.muted(scheme))
                            .keyframeAnimator(initialValue: 1.0, trigger: on) { content, scale in
                                content.scaleEffect(on ? scale : 1).rotationEffect(.degrees(on ? Double(1 - scale) * 30 : 0))
                            } keyframes: { _ in
                                LinearKeyframe(0.6, duration: 0.01)
                                SpringKeyframe(1, duration: 0.45, spring: .bouncy(duration: 0.4, extraBounce: 0.25))
                            }
                        if on {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .transition(.opacity.combined(with: .offset(x: -6)))
                        }
                    }
                    .foregroundStyle(on ? TrainingHomeStyle.ink(scheme) : TrainingHomeStyle.muted(scheme))
                    .padding(.horizontal, on ? 12 : 0)
                    .frame(maxWidth: on ? nil : .infinity, minHeight: 40)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(TrainingHomeStyle.panel(scheme))
                                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 5, y: 3)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(group.title))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("challenge-group-\(group.rawValue)")
                .opacity(appeared ? 1 : 0)
                .offset(x: appeared ? 0 : 24)
                .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.2 + Double(index) * 0.045), value: appeared)
            }
        }
        .padding(4)
        .background(scheme == .dark ? Color(red: 0.11, green: 0.14, blue: 0.15) : Color(red: 0.89, green: 0.91, blue: 0.87),
                    in: .rect(cornerRadius: 16))
    }
}

// MARK: - Pieces

/// Your ball on the path: small, uneven keepy-uppies; a tap kicks it high.
private struct PathBall: View {
    let image: CGImage?
    let kicks: Int
    let bouncing: Bool

    struct Bounce { var lift: CGFloat = 0; var squash: CGFloat = 1; var spin: Double = 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse().fill(.black.opacity(0.2)).frame(width: 22, height: 5).offset(y: 3)
            ballImage
                .keyframeAnimator(initialValue: Bounce(), repeating: bouncing) { content, value in
                    content
                        .rotationEffect(.degrees(value.spin))
                        .scaleEffect(x: 2 - value.squash, y: value.squash, anchor: .bottom)
                        .offset(y: value.lift)
                } keyframes: { _ in
                    KeyframeTrack(\.lift) {
                        LinearKeyframe(-15, duration: 0.31, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.31, timingCurve: .easeIn)
                        LinearKeyframe(0, duration: 0.1)
                        LinearKeyframe(-36, duration: 0.55, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.55, timingCurve: .easeIn)
                        LinearKeyframe(0, duration: 0.1)
                        LinearKeyframe(-9, duration: 0.17, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.17, timingCurve: .easeIn)
                        LinearKeyframe(0, duration: 0.14)
                    }
                    KeyframeTrack(\.squash) {
                        LinearKeyframe(1, duration: 0.6)
                        LinearKeyframe(0.86, duration: 0.03)
                        LinearKeyframe(1, duration: 0.08)
                        LinearKeyframe(1, duration: 1.0)
                        LinearKeyframe(0.86, duration: 0.03)
                        LinearKeyframe(1, duration: 0.08)
                        LinearKeyframe(1, duration: 0.29)
                        LinearKeyframe(0.86, duration: 0.03)
                        LinearKeyframe(1, duration: 0.26)
                    }
                    KeyframeTrack(\.spin) {
                        LinearKeyframe(360, duration: 2.4)
                    }
                }
                .keyframeAnimator(initialValue: 0.0, trigger: kicks) { content, lift in
                    content.offset(y: lift).rotationEffect(.degrees(lift * -3))
                } keyframes: { _ in
                    LinearKeyframe(-130, duration: 0.45, timingCurve: .easeOut)
                    LinearKeyframe(0, duration: 0.45, timingCurve: .easeIn)
                }
        }
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }

    private var ballImage: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 3).resizable()
            } else {
                Circle().fill(.white)
            }
        }
        .frame(width: 30, height: 30)
        .shadow(color: TrainingHomeStyle.lime.opacity(0.55), radius: 6)
    }
}

private struct PulseRing: View {
    let color: Color
    struct Pulse { var scale: CGFloat = 1; var opacity: Double = 0.8 }

    var body: some View {
        Circle().stroke(color, lineWidth: 3)
            .keyframeAnimator(initialValue: Pulse(), repeating: true) { content, value in
                content.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1.55, duration: 2.0, timingCurve: .easeOut)
                    LinearKeyframe(1.55, duration: 0.8)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: 2.0, timingCurve: .easeOut)
                    LinearKeyframe(0, duration: 0.8)
                }
            }
    }
}

struct ChallengeLevelDots: View {
    let level: JuggleChallenge.Level
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...4, id: \.self) { step in
                Circle().frame(width: 5, height: 5).opacity(step <= level.rawValue ? 1 : 0.25)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The friend row: Invite first, then one circle per friend format.
private struct ChallengeFriendRow: View {
    var appeared = true
    let onInvite: () -> Void
    let onFormat: (JuggleChallenge) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Challenge a friend").font(.headline)
                Spacer(minLength: 8)
                Text("Same rules. Best try wins.")
                    .font(.caption).foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    Button(action: onInvite) {
                        item(title: "Invite", detail: "a friend") {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(TrainingHomeStyle.buttonInk)
                                .frame(width: 58, height: 58)
                                .background(TrainingHomeStyle.lime, in: .circle)
                                .shadow(color: TrainingHomeStyle.lime.opacity(scheme == .dark ? 0.25 : 0.6), radius: 8, y: 4)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("challenge-invite")
                    .modifier(PopIn(appeared: appeared, index: 0))
                    ForEach(Array(JuggleChallenge.friendFormats.enumerated()), id: \.element.id) { index, format in
                        if let kind = format.friendKind {
                            Button { onFormat(format) } label: {
                                item(title: kind.shortName, detail: nil) {
                                    Image(systemName: kind.symbol)
                                        .font(.system(size: 21, weight: .semibold))
                                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                                        .frame(width: 58, height: 58)
                                        .background(TrainingHomeStyle.background(scheme), in: .circle)
                                        .overlay(Circle().strokeBorder(TrainingHomeStyle.line(scheme), lineWidth: 2))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("challenge-format-\(kind.rawValue)")
                            .modifier(PopIn(appeared: appeared, index: index + 1))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 14).padding(.bottom, 12)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(TrainingHomeStyle.line(scheme)))
    }

    private func item<Icon: View>(title: LocalizedStringKey, detail: LocalizedStringKey?,
                                  @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 6) {
            icon()
            Text(title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.caption2.weight(.medium)).foregroundStyle(TrainingHomeStyle.muted(scheme)).padding(.top, -5)
            }
        }
        .frame(width: 68)
        .contentShape(.rect)
    }
}

/// Friends pop in one after another when the tab arrives.
private struct PopIn: ViewModifier {
    let appeared: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .scaleEffect(appeared ? 1 : 0.3)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.42, dampingFraction: 0.58).delay(0.08 + Double(index) * 0.055), value: appeared)
    }
}

/// Opens under a tapped cup: the rule in one line and both ways to play.
private struct ChallengeCupCard: View {
    let challenge: JuggleChallenge
    let best: Int
    let done: Bool
    let arrowX: CGFloat
    let onClose: () -> Void
    let onTry: () -> Void
    let onFriend: () -> Void
    let onRules: () -> Void
    let onMark: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private func row(_ index: Int) -> some ViewModifier { RiseIn(shown: shown || reduceMotion, delay: 0.16 + Double(index) * 0.06) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        ChallengeLevelDots(level: challenge.level)
                        Text(challenge.level.title)
                        Text(verbatim: "·")
                        Text(challenge.judging.label)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
                    Text(LocalizedStringKey(challenge.title))
                        .font(TrainingHomeStyle.display(32, relativeTo: .title))
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(TrainingHomeStyle.background(scheme), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            Text(challenge.line(best: best))
                .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                .padding(.top, 8)
                .modifier(row(1))
                .accessibilityIdentifier("challenge-line")
            if let status {
                status.font(.subheadline.weight(.semibold))
                    .foregroundStyle(TrainingHomeStyle.accent(scheme))
                    .padding(.top, 4)
            }
            if challenge.judging == .timerComing {
                Text("The round timer isn’t in the app yet. Try solo opens a normal session.")
                    .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Button(action: onTry) {
                    Text(done ? "Try again" : "Try solo")
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(TrainingHomeStyle.buttonInk)
                        .background(TrainingHomeStyle.lime, in: .rect(cornerRadius: 15))
                }
                .accessibilityIdentifier("challenge-try")
                Button(action: onFriend) {
                    Label("Challenge a friend", systemImage: "person.2.fill")
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(TrainingHomeStyle.background(scheme))
                        .background(TrainingHomeStyle.ink(scheme), in: .rect(cornerRadius: 15))
                }
                .accessibilityIdentifier("challenge-friend")
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .padding(.top, 14)
            .modifier(row(2))
            HStack {
                Button("See the full rules", action: onRules)
                    .accessibilityIdentifier("challenge-rules")
                Spacer()
                if challenge.judging == .practice && !done {
                    Button("Mark as done", action: onMark)
                        .accessibilityIdentifier("challenge-mark")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(TrainingHomeStyle.accent(scheme))
            .buttonStyle(.plain)
            .padding(.top, 12)
            .modifier(row(3))
        }
        .padding(16)
        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(TrainingHomeStyle.line(scheme)))
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(TrainingHomeStyle.panel(scheme))
                .frame(width: 16, height: 16)
                .overlay(alignment: .topLeading) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 16)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: 16, y: 0)) }
                        .stroke(TrainingHomeStyle.line(scheme), lineWidth: 1)
                }
                .rotationEffect(.degrees(45))
                .offset(x: arrowX - 8, y: -8)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 22, y: 14)
        .contentShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("challenge-card")
        .onAppear { shown = true }
    }

    private var status: Text? {
        switch challenge.rule {
        case .streak, .beatYourBest:
            best > 0 ? Text("Your best streak: \(best)") : nil
        default:
            done ? Text("You marked this done.") : nil
        }
    }
}

private struct RiseIn: ViewModifier {
    let shown: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .animation(.easeOut(duration: 0.32).delay(delay), value: shown)
    }
}

/// The full rules for one challenge.
private struct ChallengeRulesSheet: View {
    let challenge: JuggleChallenge
    let best: Int
    let done: Bool
    let onTry: () -> Void
    let onFriend: () -> Void
    let onMark: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ChallengeHero(challenge: challenge, best: best, done: done)
                Text(LocalizedStringKey(challenge.title))
                    .font(TrainingHomeStyle.display(44, relativeTo: .largeTitle))
                    .padding(.top, 20)
                Text(challenge.line(best: best))
                    .font(.body).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    fact("list.bullet.clipboard", title: "The rule", text: Text(challenge.objective))
                    fact(challenge.judging.symbol, title: challenge.judging.label, text: Text(challenge.judging.detail))
                    if let note = challenge.timeNote { fact("stopwatch", title: "Time", text: Text(note)) }
                    if !challenge.isFriend { fact("trophy", title: "Your best", text: bestText) }
                }
                .padding(.horizontal, 16)
                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.line(scheme)))
                .padding(.top, 18)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if challenge.isFriend {
                    primary("Invite a friend", action: onFriend)
                } else {
                    primary(done ? "Try again" : "Try solo", action: onTry)
                    Button(action: onFriend) {
                        Label("Challenge a friend", systemImage: "person.2.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(TrainingHomeStyle.background(scheme))
                            .background(TrainingHomeStyle.ink(scheme), in: .rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    if challenge.judging == .practice && !done {
                        Button("I made it. Mark as done", action: onMark)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TrainingHomeStyle.accent(scheme))
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .background(TrainingHomeStyle.background(scheme))
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.top, 30).padding(.trailing, 30)
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("challenge-sheet-close")
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .presentationDragIndicator(.visible)
    }

    private var bestText: Text {
        switch challenge.rule {
        case .streak, .beatYourBest:
            best > 0 ? Text("\(best) in a row") : Text("Not tried yet. It stays open until you finish it.")
        default:
            done ? Text("Marked done") : Text("Not done yet. It stays open until you finish it.")
        }
    }

    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(TrainingHomeStyle.buttonInk)
                .background(TrainingHomeStyle.lime, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("challenge-rules-primary")
    }

    private func fact(_ symbol: String, title: LocalizedStringKey, text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TrainingHomeStyle.accent(scheme))
                .frame(width: 30, height: 30)
                .background(TrainingHomeStyle.background(scheme), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                text.font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(TrainingHomeStyle.line(scheme)).frame(height: 1).opacity(0.7) }
    }
}

/// The dark pitch card at the top of a challenge, like Home's stage.
private struct ChallengeHero: View {
    let challenge: JuggleChallenge
    let best: Int
    let done: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(challenge.group.title).textCase(.uppercase).tracking(1.6)
                    .font(.caption.weight(.bold)).foregroundStyle(TrainingHomeStyle.lime)
                if done {
                    Label("Done", systemImage: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TrainingHomeStyle.buttonInk)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(TrainingHomeStyle.lime, in: .capsule)
                }
            }
            Spacer(minLength: 18)
            Text(challenge.mark(best: best))
                .font(TrainingHomeStyle.display(96, relativeTo: .largeTitle))
                .lineLimit(1).minimumScaleFactor(0.5)
            HStack(spacing: 6) {
                ChallengeLevelDots(level: challenge.level).foregroundStyle(TrainingHomeStyle.lime)
                Text(challenge.level.title)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
        .background(alignment: .bottomTrailing) {
            ChallengeKitView(challenge: challenge, best: best, state: done ? .done : .next, size: 128)
                .padding(.trailing, 14).padding(.bottom, 10)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.17, green: 0.25, blue: 0.15), Color(red: 0.09, green: 0.14, blue: 0.10),
                                    TrainingHomeStyle.cardBlack],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 26)
        )
    }
}

/// Sends a challenge to a friend. Matches aren't tracked in the app yet, so this shares
/// the rules and a link; both players compare their best tries.
struct ChallengeInviteSheet: View {
    let challenge: JuggleChallenge
    /// Closes the whole sheet when the invite was pushed from the format list.
    var onClose: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private var format: JuggleChallenge { challenge.friendVersion ?? challenge }
    private var line: String {
        format.friendKind?.line ?? "\(challenge.line(best: 0)) Three tries each. Your best try counts."
    }
    private var message: String {
        "\(format.title) in Juggle Dude: \(line) Can you beat me? \(AppUpdateNotice.appStoreURL.absoluteString)"
    }
    private var judgedTogether: Bool { format.judging == .checkedTogether || challenge.judging == .practice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        avatar(Text("You"), filled: true)
                        Text(verbatim: format.friendKind?.isTeam == true ? "+" : "vs")
                            .font(TrainingHomeStyle.display(22, relativeTo: .title3))
                            .foregroundStyle(.white.opacity(0.6))
                        avatar(Text(Image(systemName: "person.fill")), filled: false)
                    }
                    .padding(.bottom, 8)
                    Group {
                        if format.id != challenge.id {
                            Text("Based on \(challenge.title)")
                        } else if format.isFriend {
                            Text("Friend match")
                        } else {
                            Text("Same rules")
                        }
                    }
                    .textCase(.uppercase).tracking(1.6)
                    .font(.caption.weight(.bold)).foregroundStyle(TrainingHomeStyle.lime)
                    Text(LocalizedStringKey(format.title))
                        .font(TrainingHomeStyle.display(38, relativeTo: .largeTitle))
                    Text(line).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [Color(red: 0.17, green: 0.25, blue: 0.15), TrainingHomeStyle.cardBlack],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 26)
                )

                VStack(spacing: 0) {
                    term("Tries", value: format.number == 56 || format.number == 60 ? Text("1 per round") : Text("3 each"))
                    term(format.friendKind?.isTeam == true ? "Goal" : "Winner", value: winner)
                    term("Play", value: Text("At different times"))
                    term("Replays", value: judgedTogether ? Text("Shared with each other") : Text("Stay private"))
                }
                .padding(.horizontal, 16)
                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(TrainingHomeStyle.line(scheme)))
                .padding(.top, 16)

                Text("This sends the rules and a link in a message. Keeping score for matches inside the app comes next.")
                    .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            ShareLink(item: message) {
                Label("Share invite", systemImage: "square.and.arrow.up")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(TrainingHomeStyle.buttonInk)
                    .background(TrainingHomeStyle.lime, in: .rect(cornerRadius: 16))
            }
            .accessibilityIdentifier("challenge-share-invite")
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            .background(TrainingHomeStyle.background(scheme))
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .navigationTitle("Challenge a friend")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { (onClose ?? { dismiss() })() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
                    .accessibilityIdentifier("challenge-sheet-close")
            }
        }
    }

    private var winner: Text {
        if format.friendKind?.isTeam == true { return Text("100 touches together") }
        if format.friendKind?.lowestWins == true { return Text("Lowest time") }
        switch challenge.rule {
        case .race, .inTime: return Text("Lowest time")
        default: break
        }
        if judgedTogether { return Text("Agreed from the video") }
        return Text("Highest score")
    }

    private func avatar(_ label: Text, filled: Bool) -> some View {
        label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(filled ? TrainingHomeStyle.buttonInk : .white.opacity(0.7))
            .frame(width: 50, height: 50)
            .background { if filled { Circle().fill(TrainingHomeStyle.lime) } }
            .overlay { if !filled { Circle().strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [4, 4])) } }
    }

    private func term(_ title: LocalizedStringKey, value: Text) -> some View {
        HStack {
            Text(title).foregroundStyle(TrainingHomeStyle.muted(scheme))
            Spacer(minLength: 12)
            value.fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(TrainingHomeStyle.line(scheme)).frame(height: 1).opacity(0.7) }
    }
}

/// All eight friend formats, from the Invite button.
private struct ChallengeFriendFormatsSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Same rules for both of you. Play whenever suits you, then compare your best tries. Every cup on the path has a Challenge a friend button too.")
                        .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    ForEach(JuggleChallenge.friendFormats) { format in
                        if let kind = format.friendKind {
                            NavigationLink(value: format.id) {
                                HStack(spacing: 12) {
                                    Image(systemName: kind.symbol)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                                        .frame(width: 44, height: 44)
                                        .background(TrainingHomeStyle.background(scheme), in: .rect(cornerRadius: 14))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(LocalizedStringKey(format.title)).font(.subheadline.weight(.semibold))
                                        Text(kind.line).font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                                }
                                .multilineTextAlignment(.leading)
                                .padding(12)
                                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(TrainingHomeStyle.line(scheme)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("challenge-friend-format-\(kind.rawValue)")
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(TrainingHomeStyle.background(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .navigationTitle("Challenge a friend")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let challenge = JuggleChallenge.with(id: id) { ChallengeInviteSheet(challenge: challenge, onClose: { dismiss() }) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close"))
                        .accessibilityIdentifier("challenge-sheet-close")
                }
            }
        }
    }
}
