import SwiftUI

/// The wait after Stop or an import. A ball rolls along a path through four checkpoints, one
/// per processing step. Each checkpoint pops its check as the ball arrives, and the last one
/// celebrates before the editor takes over.
struct ProcessingOverlay: View {
    var progress: Double
    var stepIndex: Int
    var statusMessage: String? = nil
    var onCancel: (() -> Void)? = nil
    var isPaused = false
    /// Step names and coach's tips; Power Shot passes its own.
    var labels = ProcessingLabels.juggling
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var model = BallPathModel()
    @State private var exiting = false

    static var steps: [String] { ProcessingLabels.juggling.steps }

    var body: some View {
        ZStack {
            // The ground appears at once (no black gap after Stop); only the content moves.
            SessionStyle.background.opacity(0.97)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
            PitchMarkings().ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.top, 8)
                    .sessionEntrance(appeared, offset: -12)
                BallPathMap(model: model, step: stepIndex, exiting: exiting, isPaused: isPaused, steps: labels.steps)
                    .padding(.top, 18).padding(.bottom, 6)
                ProcessingTips(isPaused: isPaused, tips: labels.tips)
                    .padding(.vertical, 12)
                    .sessionEntrance(appeared, order: 7, offset: 10)
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .font(.callout).padding(.bottom, 12)
                        .accessibilityIdentifier("cancel-video-import")
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 460)
            .padding(.horizontal, 22)
            // Exit beat: once the last checkpoint has celebrated, the screen lifts away.
            .scaleEffect(exiting && !reduceMotion ? 1.04 : 1)
            .opacity(exiting ? 0 : 1)
            .animation(reduceMotion ? SessionMotion.fade : .easeIn(duration: 0.22), value: exiting)
        }
        .transition(.opacity)
        .onAppear { appeared = true; ProcessingBallImage.shared.load() }
        .onChange(of: model.finishedAt != nil) { _, finished in
            guard finished else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 360))
                exiting = true
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.85), trigger: model.checkpoints) { _, count in count < 4 }
        .sensoryFeedback(.success, trigger: model.finishedAt != nil) { _, finished in finished }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Processing your session, \(percent) percent. \(title)")
    }

    private var percent: Int { Int((min(1, max(0, stepIndex >= 4 ? 1 : progress)) * 100).rounded()) }
    private var title: String { statusMessage ?? (model.finishedAt != nil ? "Ready!" : labels.steps[min(3, max(0, stepIndex))]) }

    private var header: some View {
        VStack(spacing: 2) {
            Text(labels.heading)
                .font(.system(size: 11, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(SessionStyle.mint)
            Text("\(percent)%")
                .font(.system(size: 64, weight: .heavy, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText(value: Double(percent)))
                .animation(.snappy(duration: 0.3), value: percent)
            ZStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(model.finishedAt != nil ? SessionStyle.mint : SessionStyle.secondary)
                    // Each step name keeps its own width, so a longer one is never cut short.
                    .fixedSize()
                    .id(title)
                    .transition(.blurReplace(.upUp))
            }
            .animation(.smooth(duration: 0.4), value: title)
        }
    }
}

// MARK: - The path

/// Where things sit: a kick-off spot, then the four checkpoints zig-zagging down the screen,
/// joined by S-curves. Positions along it are in checkpoint units (0 = kick-off, 4 = finish)
/// and move by arc length, so the ball rolls at an even pace within each stretch.
struct BallPathLayout {
    let points: [CGPoint]
    private let samples: [[CGPoint]]
    private let lengths: [[CGFloat]]
    private static let perSegment = 48

    init(size: CGSize) {
        let w = size.width, h = size.height
        points = [CGPoint(x: w * 0.5, y: h * 0.035), CGPoint(x: w * 0.17, y: h * 0.24),
                  CGPoint(x: w * 0.83, y: h * 0.48), CGPoint(x: w * 0.17, y: h * 0.72),
                  CGPoint(x: w * 0.83, y: h * 0.95)]
        var samples: [[CGPoint]] = [], lengths: [[CGFloat]] = []
        for i in 0..<4 {
            let a = points[i], b = points[i + 1], dy = b.y - a.y
            let c1 = CGPoint(x: a.x, y: a.y + dy * 0.62), c2 = CGPoint(x: b.x, y: b.y - dy * 0.62)
            var stretch: [CGPoint] = [], running: [CGFloat] = [], total: CGFloat = 0
            for k in 0...Self.perSegment {
                let t = CGFloat(k) / CGFloat(Self.perSegment), u = 1 - t
                let x: CGFloat = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
                let y: CGFloat = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
                let p = CGPoint(x: x, y: y)
                if let last = stretch.last { total += hypot(p.x - last.x, p.y - last.y) }
                stretch.append(p); running.append(total)
            }
            samples.append(stretch); lengths.append(running)
        }
        self.samples = samples
        self.lengths = lengths
    }

    func point(at position: Double) -> CGPoint {
        let s = min(4, max(0, position))
        let segment = min(3, Int(s))
        let running = lengths[segment], target = CGFloat(s - Double(segment)) * (running.last ?? 0)
        var k = 1
        while k < running.count - 1 && running[k] < target { k += 1 }
        let span = running[k] - running[k - 1], q = span > 0 ? (target - running[k - 1]) / span : 0
        let a = samples[segment][k - 1], b = samples[segment][k]
        return CGPoint(x: a.x + (b.x - a.x) * q, y: a.y + (b.y - a.y) * q)
    }

    func path(from start: Double, to end: Double) -> Path {
        var path = Path()
        guard end > start + 0.0001 else { return path }
        let count = max(2, Int((end - start) * 40))
        path.move(to: point(at: start))
        for k in 1...count { path.addLine(to: point(at: start + (end - start) * Double(k) / Double(count))) }
        return path
    }
}

/// Moves the ball. While a step runs the ball creeps toward its checkpoint, slowing as it
/// nears, so the wait always looks alive; when the step really finishes it rolls the rest
/// of the way and the checkpoint pops. It never moves backward.
@Observable
final class BallPathModel {
    struct Spark {
        let point: CGPoint
        let born: Date
        let seed: Int
    }

    private(set) var position: Double = 0
    private(set) var ballPoint: CGPoint?
    private(set) var angle: Double = 0
    private(set) var reached: [Date?] = [nil, nil, nil, nil]
    private(set) var checkpoints = 0
    private(set) var appearedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var sparks: [Spark] = []
    private var lastDate: Date?
    private var furthestStep = -1
    private var stepStarted = Date()
    private var lastSpark: Date?
    private var sparkSeed = 0

    static let entrance = 0.95
    static let ballRadius: CGFloat = 17

    var activeCheckpoint: Int? { reached.firstIndex { $0 == nil } }

    /// The ball drops in once its image is ready and the track has unrolled.
    func dropStart(ballReady: Date?) -> Date? {
        guard let appearedAt, let ballReady else { return nil }
        return max(appearedAt.addingTimeInterval(0.12), ballReady)
    }

    func advance(to date: Date, step: Int, layout: BallPathLayout, reduceMotion: Bool, ballReady: Date?) {
        if appearedAt == nil { appearedAt = date }
        let dt = min(1.0 / 20, max(0, date.timeIntervalSince(lastDate ?? date)))
        lastDate = date
        if step > furthestStep { furthestStep = step; stepStarted = date }
        let completed = Double(min(4, max(0, furthestStep)))
        let since = date.timeIntervalSince(appearedAt ?? date)

        var target = completed >= 4 ? 4 : completed + 0.86 * (1 - exp(-date.timeIntervalSince(stepStarted) / 2.6))
        // Roll clear of a checkpoint just reached, so its check is never hidden under the ball.
        if completed > 0, completed < 4 { target = max(target, completed + 0.22) }
        let landed = dropStart(ballReady: ballReady).map { date.timeIntervalSince($0) > (reduceMotion ? 0 : 0.6) } ?? false
        if since < Self.entrance || !landed { target = 0 }
        if position < target {
            // Ease toward the target, never faster than about two and a half stretches a second.
            // A finished step is reached at a steady roll rather than a long, slow ease-in.
            var move = (target - position) * (1 - exp(-dt * 5.5))
            if position < completed { move = max(move, 1.6 * dt) }
            position = min(target, position + min(max(move, 0), 2.6 * dt))
        }

        let point = layout.point(at: position)
        if let previous = ballPoint {
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            angle += Double(distance / Self.ballRadius) * (point.x >= previous.x ? 1 : -1)
            if !reduceMotion, distance > 0.25, date.timeIntervalSince(lastSpark ?? .distantPast) > 0.04 {
                sparkSeed += 1
                sparks.append(Spark(point: point, born: date, seed: sparkSeed))
                lastSpark = date
            }
        }
        ballPoint = point
        sparks.removeAll { date.timeIntervalSince($0.born) > 0.6 }

        for index in 0..<4 where reached[index] == nil && position >= Double(index + 1) - 0.002 {
            reached[index] = date
            checkpoints += 1
            if index == 3 { finishedAt = date }
        }
    }
}

struct BallPathMap: View {
    let model: BallPathModel
    let step: Int
    let exiting: Bool
    var isPaused = false
    var steps = ProcessingLabels.juggling.steps
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let mint = SessionStyle.mint
    private let gold = Theme.star

    var body: some View {
        GeometryReader { geometry in
            let layout = BallPathLayout(size: geometry.size)
            TimelineView(.animation(minimumInterval: animationInterval, paused: exiting || isPaused)) { timeline in
                let now = timeline.date
                let t = model.appearedAt.map { now.timeIntervalSince($0) } ?? 0
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(&context, layout: layout, now: now, t: t) }
                    ForEach(0..<4, id: \.self) { index in
                        checkpointLabel(index, layout: layout, size: geometry.size, t: t)
                    }
                    ball(now: now, t: t)
                }
                .onChange(of: now) { _, date in
                    model.advance(to: date, step: step, layout: layout, reduceMotion: reduceMotion,
                                  ballReady: ProcessingBallImage.shared.readyAt)
                }
            }
        }
    }

    // MARK: Drawing

    private var animationInterval: Double? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--thermal-original-overlay") { return nil }
        #endif
        return 1.0 / 30
    }

    /// Draw-on during the entrance: the track unrolls from the kick-off spot to the finish.
    private func drawn(_ t: Double) -> Double {
        reduceMotion ? 4 : 4 * (1 - pow(1 - min(1, t / BallPathModel.entrance), 3))
    }

    /// When the unrolling track reaches checkpoint `index`.
    private func arrival(_ index: Int) -> Double {
        reduceMotion ? 0 : BallPathModel.entrance * (1 - cbrt(1 - Double(index + 1) / 4))
    }

    private func draw(_ context: inout GraphicsContext, layout: BallPathLayout, now: Date, t: Double) {
        let lit = model.position, end = drawn(t)
        // The road ahead: dots drifting forward along the path.
        if end > lit {
            context.stroke(layout.path(from: lit, to: end), with: .color(.white.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [0.1, 10],
                                              dashPhase: reduceMotion ? 0 : CGFloat(-t * 16)))
        }
        // Kick-off spot.
        let start = layout.points[0]
        context.stroke(Path(ellipseIn: CGRect(x: start.x - 7, y: start.y - 7, width: 14, height: 14)),
                       with: .color(.white.opacity(0.25 * min(1, t * 4))), lineWidth: 1.5)
        // The road behind: a lit, glowing line from the kick-off to the ball.
        if lit > 0.001 {
            let road = layout.path(from: 0, to: lit)
            let head = layout.point(at: lit)
            let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: [SessionStyle.deepGreen, mint]),
                                                                 startPoint: start, endPoint: head)
            var glow = context
            glow.addFilter(.blur(radius: 7))
            glow.stroke(road, with: .color(mint.opacity(0.45)), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            context.stroke(road, with: shading, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.stroke(road, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            // A brighter comet head just behind the ball.
            let comet = layout.path(from: max(0, lit - 0.22), to: lit)
            var cometGlow = context
            cometGlow.addFilter(.blur(radius: 4))
            cometGlow.stroke(comet, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        // Sparkles shed by the rolling ball.
        for spark in model.sparks {
            let age = now.timeIntervalSince(spark.born), f = age / 0.6
            let dx = CGFloat(sin(Double(spark.seed) * 12.9898) * 16 * f)
            let dy = CGFloat(cos(Double(spark.seed) * 7.233) * 16 * f)
            let size = CGFloat(2.6 * (1 - f))
            let rect = CGRect(x: spark.point.x + dx - size, y: spark.point.y + dy - size, width: size * 2, height: size * 2)
            let tint: Color = spark.seed.isMultiple(of: 3) ? .white : mint
            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.8 * (1 - f))))
        }
        for index in 0..<4 { drawCheckpoint(&context, index, center: layout.points[index + 1], now: now, t: t) }
    }

    private func drawCheckpoint(_ context: inout GraphicsContext, _ index: Int, center c: CGPoint, now: Date, t: Double) {
        let appear = t - arrival(index)
        guard appear > 0 else { return }
        // Pops in as the track reaches it.
        let wobble = 0.35 * exp(-appear * 9) * sin(min(1, appear / 0.32) * .pi * 1.6)
        let enter = reduceMotion ? 1 : 1 + wobble - 0.6 * exp(-appear * 16)
        let radius: CGFloat = 17
        var node = context
        node.translateBy(x: c.x, y: c.y)
        node.scaleBy(x: enter, y: enter)
        let ring = Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))

        if let reached = model.reached[index] {
            let age = now.timeIntervalSince(reached)
            let final = index == 3
            if !reduceMotion && age < (final ? 0.9 : 0.6) {
                burst(&context, at: c, radius: radius, age: age, final: final, seed: index)
            }
            let pop = reduceMotion ? 1 : 1 + 0.42 * exp(-age * 8) * sin(min(1, age / 0.38) * .pi)
            node.scaleBy(x: pop, y: pop)
            var halo = node
            halo.addFilter(.blur(radius: 7))
            halo.fill(ring, with: .color(mint.opacity(0.55)))
            node.fill(ring, with: .linearGradient(Gradient(colors: [Color(red: 0.6, green: 1, blue: 0.8), mint]),
                                                  startPoint: CGPoint(x: 0, y: -radius), endPoint: CGPoint(x: 0, y: radius)))
            // The check draws itself in.
            let check = Path { p in
                p.move(to: CGPoint(x: -7, y: 0.5)); p.addLine(to: CGPoint(x: -2, y: 5.5)); p.addLine(to: CGPoint(x: 7.5, y: -5))
            }
            let drawnCheck = reduceMotion ? 1 : min(1, max(0, (age - 0.05) / 0.22))
            node.stroke(check.trimmedPath(from: 0, to: drawnCheck), with: .color(SessionStyle.background),
                        style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
        } else if model.activeCheckpoint == index && t > BallPathModel.entrance {
            // Waiting for the ball: a sonar ping and a turning arc.
            if !reduceMotion {
                let ping = (t * 0.8).truncatingRemainder(dividingBy: 1)
                let r = radius + CGFloat(ping) * 16
                node.stroke(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                            with: .color(mint.opacity(0.5 * (1 - ping))), lineWidth: 1.5)
            }
            node.fill(ring, with: .color(mint.opacity(0.14)))
            node.stroke(ring, with: .color(mint.opacity(0.35)), lineWidth: 2)
            var spinner = node
            spinner.rotate(by: .degrees(reduceMotion ? 0 : (t * 300).truncatingRemainder(dividingBy: 360)))
            let arc = Path { $0.addArc(center: .zero, radius: radius - 1, startAngle: .zero, endAngle: .degrees(100), clockwise: false) }
            spinner.stroke(arc, with: .color(mint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            node.fill(Path(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8)), with: .color(mint))
        } else {
            node.fill(ring, with: .color(SessionStyle.background))
            node.stroke(ring, with: .color(.white.opacity(0.24)), lineWidth: 1.8)
        }
    }

    /// Shockwave rings and a ring of sparks from the moment the ball arrives; bigger and gold at the finish.
    private func burst(_ context: inout GraphicsContext, at c: CGPoint, radius: CGFloat, age: Double, final: Bool, seed: Int) {
        let q = age / (final ? 0.9 : 0.6), eased = 1 - pow(1 - q, 3)
        for wave in 0..<(final ? 2 : 1) {
            let w = max(0, eased - Double(wave) * 0.18)
            let r = radius + CGFloat(w) * (final ? 78 : 40)
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color((final ? gold : mint).opacity(0.7 * (1 - q))), lineWidth: final ? 2.5 : 2)
        }
        let count = final ? 26 : 12
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * .pi + Double(seed)
            let spread = CGFloat(0.75 + 0.5 * abs(sin(Double(k) * 3.7)))
            let reach = radius + 6 + CGFloat(eased) * (final ? 74 : 38) * spread
            let dir = CGPoint(x: CGFloat(cos(a)), y: CGFloat(sin(a)))
            let p = CGPoint(x: c.x + dir.x * reach, y: c.y + dir.y * reach)
            let tail = CGPoint(x: c.x + dir.x * (reach - 7), y: c.y + dir.y * (reach - 7))
            let tint: Color = final ? [gold, mint, .white][k % 3] : (k.isMultiple(of: 2) ? mint : .white)
            context.stroke(Path { $0.move(to: tail); $0.addLine(to: p) }, with: .color(tint.opacity(1 - q)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    // MARK: Labels and ball

    private func checkpointLabel(_ index: Int, layout: BallPathLayout, size: CGSize, t: Double) -> some View {
        let c = layout.points[index + 1], onLeft = c.x < size.width / 2
        let done = model.reached[index] != nil, active = !done && model.activeCheckpoint == index
        let status = done ? (index == 3 ? "Ready" : "Done") : active ? "In progress" : "Up next"
        let appear = min(1, max(0, (t - arrival(index) - 0.05) / 0.3))
        let statusColor: Color = active ? mint : done ? mint.opacity(0.8) : SessionStyle.secondary.opacity(0.6)
        return VStack(alignment: onLeft ? .leading : .trailing, spacing: 3) {
            Text(steps[index])
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(done || active ? .white : .white.opacity(0.42))
            ZStack(alignment: onLeft ? .leading : .trailing) {
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                    .id(status)
                    .transition(.blurReplace(.upUp))
            }
        }
        .animation(.smooth(duration: 0.35), value: status)
        .frame(width: size.width * 0.58, alignment: onLeft ? .leading : .trailing)
        .position(x: onLeft ? c.x + 30 + size.width * 0.29 : c.x - 30 - size.width * 0.29, y: c.y)
        .opacity(appear)
        .offset(x: reduceMotion ? 0 : (onLeft ? -1 : 1) * CGFloat(1 - appear) * 12)
    }

    @ViewBuilder private func ball(now: Date, t: Double) -> some View {
        if let p = model.ballPoint, let dropStart = model.dropStart(ballReady: ProcessingBallImage.shared.readyAt) {
            let dropped = now.timeIntervalSince(dropStart)
            let lift = ballLift(now: now, dropped: dropped)
            let scale = 1 + lift
            ZStack {
                Ellipse().fill(.black.opacity(0.45 / Double(scale)))
                    .frame(width: 30, height: 9)
                    .blur(radius: 1.5 + 3 * lift)
                    .offset(x: 3 * lift, y: 15 + 16 * lift)
                ProcessingBall()
                    .frame(width: BallPathModel.ballRadius * 2, height: BallPathModel.ballRadius * 2)
                    .rotationEffect(.radians(model.angle))
                    .scaleEffect(scale)
                    .shadow(color: SessionStyle.mint.opacity(0.35), radius: 10)
            }
            .position(p)
            .opacity(reduceMotion ? 1 : min(1, max(0, dropped * 6)))
        }
    }

    /// How high the ball is (seen from above, higher means bigger): it drops onto the kick-off
    /// spot during the entrance, then hops at every checkpoint it reaches.
    private func ballLift(now: Date, dropped: Double) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let drop = min(1, max(0, dropped / 0.45)), fall = 1 - drop
        var lift = CGFloat(fall * fall) * 1.3
        let settle = dropped - 0.45
        if settle > 0, settle < 0.22 { lift += CGFloat(sin(settle / 0.22 * .pi)) * 0.12 }
        if let hop = model.reached.compactMap({ $0 }).max() {
            let age = now.timeIntervalSince(hop)
            if age < 0.38 { lift += CGFloat(sin(age / 0.38 * .pi)) * 0.34 }
        }
        return lift
    }
}

/// The app's own classic ball, rendered once off the main thread and shared.
@Observable
final class ProcessingBallImage {
    static let shared = ProcessingBallImage()
    private(set) var image: CGImage?
    /// When the render finished (or failed); the ball only appears after this.
    private(set) var readyAt: Date?
    private var loading = false

    func load() {
        guard readyAt == nil, !loading else { return }
        loading = true
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                BallSkinSphereRenderer.image(skin: .classic, time: 1.4)
            }.value
            image = rendered
            readyAt = Date()
        }
    }
}

struct ProcessingBall: View {
    private var store = ProcessingBallImage.shared

    var body: some View {
        ZStack {
            if let image = store.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if store.readyAt != nil {
                Circle().fill(.white)
            }
        }
        .onAppear { store.load() }
    }
}

/// Faint pitch markings behind the path.
private struct PitchMarkings: View {
    var body: some View {
        Canvas { context, size in
            let mid = size.height * 0.58, r = min(size.width, size.height) * 0.24
            var lines = Path()
            lines.addEllipse(in: CGRect(x: size.width / 2 - r, y: mid - r, width: r * 2, height: r * 2))
            lines.move(to: CGPoint(x: 0, y: mid)); lines.addLine(to: CGPoint(x: size.width, y: mid))
            lines.addEllipse(in: CGRect(x: size.width / 2 - 3, y: mid - 3, width: 6, height: 6))
            context.stroke(lines, with: .color(.white.opacity(0.045)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// A coach's tip that changes every few seconds, with a thin bar counting down to the next.
struct ProcessingTips: View {
    var isPaused = false
    var tips = ProcessingLabels.juggling.tips
    private static let period = 5.0
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            let elapsed = context.date.timeIntervalSince(start) / Self.period
            let index = Int(elapsed) % tips.count
            let phase = elapsed - floor(elapsed)
            VStack(spacing: 7) {
                Text("Coach's tip")
                    .font(.system(size: 10, weight: .bold)).tracking(1.6).textCase(.uppercase)
                    .foregroundStyle(SessionStyle.mint)
                ZStack {
                    Text(tips[index])
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .id(index)
                        .transition(.blurReplace(.upUp))
                }
                .animation(.smooth(duration: 0.45), value: index)
                Capsule().fill(.white.opacity(0.12))
                    .frame(width: 40, height: 2)
                    .overlay(alignment: .leading) {
                        Capsule().fill(SessionStyle.mint.opacity(0.8)).frame(width: 40 * phase, height: 2)
                    }
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the processing screen says for each kind of session. Four steps, any number of tips.
struct ProcessingLabels: Equatable {
    var heading = "Processing your session"
    var steps: [String]
    var tips: [String]

    static let juggling = ProcessingLabels(
        steps: ["Saving your video", "Tracking the ball", "Counting touches", "Building your replay"],
        tips: ["Lock your ankle and point your toes.",
               "Small touches keep the ball close.",
               "Stay light on the balls of your feet.",
               "Watch the ball, not your feet.",
               "Aim for waist height, no higher.",
               "Use both feet to build balance."])

    static let powerShot = ProcessingLabels(
        heading: "Processing your shot",
        steps: ["Saving your shot", "Finding the ball", "Tracing the flight", "Building your replay"],
        tips: ["Plant your standing foot beside the ball.",
               "Strike through the middle of the ball.",
               "Lock your ankle as you make contact.",
               "Follow through toward your target.",
               "Film from behind, with the goal in view.",
               "Keep the whole flight in the frame."])
}
