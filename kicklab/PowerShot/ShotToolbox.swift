import SwiftUI
import simd

enum ShotTool: String, Identifiable {
    case effects = "Effects", graph = "Graph", camera = "Camera"
    var id: String { rawValue }
}

/// The shot's Customize panel, built like the juggling one: tools open in place, the tray's
/// height glides to fit each page on one spring, and the old page blurs away as the next one
/// settles in. A shot has tools for its trail, graph and camera replay.
struct ShotToolbox: View {
    @Binding var style: ShotTrailStyle
    @Binding var intensity: Double
    @Binding var graphStyle: ShotGraphStyle
    @Binding var showGraph: Bool
    @Binding var camera: ShotCameraSettings
    @Binding var original: Bool
    let flight: ShotFlight?
    var distance: BallDistanceTimeline? = nil
    let time: Double
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    let hasBallTrack: Bool
    let source: URL?
    let strike: Double
    let frames: ShotSourceFrames
    @Binding var spatialEdit: ShotCameraSpatialEdit?
    @Binding var reviewFrames: [Double]
    let onPicking: (Bool) -> Void
    let onSeek: (Double) -> Void
    @Binding var page: ShotTool?
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var kicks: [ShotTrailStyle: Int] = [:]
    @State private var trayHeight: CGFloat = 0
    @State private var forward = true

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
            .padding(.horizontal, -16)
            .mask { Rectangle().padding(.horizontal, -16).padding(.top, -400).padding(.bottom, -16) }
        }
        .padding(16).foregroundStyle(.white)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .onAppear { appeared = true }
        .sensoryFeedback(.selection, trigger: style)
        .sensoryFeedback(.impact(weight: .light), trigger: page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shot-toolbox")
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
                .accessibilityIdentifier("shot-tools-back")
                .transition(.sessionPop(scale: 0.4))
            }
            ZStack(alignment: .leading) {
                Text(page?.rawValue ?? "Customize shot").font(.system(size: 17, weight: .semibold))
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
            .accessibilityIdentifier("shot-close-tools")
            .sessionEntrance(appeared, order: 1, offset: 0, scale: 0.5)
        }
    }

    private var swap: AnyTransition {
        if reduceMotion { return .opacity }
        let lean: CGFloat = forward ? 14 : -14
        return .asymmetric(
            insertion: .modifier(active: ShotTraySwap(hidden: true, lean: lean), identity: ShotTraySwap(hidden: false, lean: lean))
                .animation(.smooth(duration: 0.3).delay(0.05)),
            removal: .modifier(active: ShotTraySwap(hidden: true, lean: -lean * 0.6), identity: ShotTraySwap(hidden: false, lean: 0))
                .animation(.easeOut(duration: 0.14)))
    }

    private func go(_ next: ShotTool?) {
        forward = next != nil
        withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { page = next }
    }

    private func fit(_ height: CGFloat, for key: ShotTool?) {
        guard key == page, abs(height - trayHeight) > 0.5 else { return }
        if trayHeight == 0 { trayHeight = height; return }
        withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { trayHeight = height }
    }

    // MARK: - Grid

    private var grid: some View {
        HStack(spacing: 9) {
            tile(.effects).sessionEntrance(appeared, order: 1, offset: 14, scale: 0.88)
            tile(.graph).sessionEntrance(appeared, order: 2, offset: 14, scale: 0.88)
            tile(.camera).sessionEntrance(appeared, order: 3, offset: 14, scale: 0.88)
        }
        .padding(.horizontal, 16)
    }

    private func tile(_ tool: ShotTool) -> some View {
        Button { go(tool) } label: {
            VStack(spacing: 6) {
                preview(for: tool).frame(height: 62).accessibilityHidden(true)
                VStack(spacing: 3) {
                    Text(tool.rawValue).font(.system(size: 12, weight: .semibold))
                    Text(tool == .effects ? style.title : tool == .graph ? graphStyle.title : camera.style.title)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        .contentTransition(.interpolate)
                }
                .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.035)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.07), lineWidth: 0.5) }
            .contentShape(.rect(cornerRadius: 17))
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .accessibilityLabel(tool.rawValue)
        .accessibilityIdentifier("shot-tool-\(tool.rawValue.lowercased())")
    }

    @ViewBuilder private func preview(for tool: ShotTool) -> some View {
        switch tool {
        case .effects:
            ShotTrailPreview(style: style == .none ? .limeRibbon : style)
                .clipShape(.rect(cornerRadius: 10))
        case .graph:
            ShotGraphThumbnail(style: graphStyle, palette: style.palette)
                .clipShape(.rect(cornerRadius: 10))
        case .camera:
            Image(systemName: camera.style == .none ? "viewfinder" : camera.style.symbol)
                .font(.system(size: 32, weight: .light)).foregroundStyle(SessionStyle.mint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pages

    @ViewBuilder private func pageContent(_ tool: ShotTool) -> some View {
        switch tool {
        case .effects: effectsPage
        case .graph:
            ShotGraphPicker(style: $graphStyle, showGraph: $showGraph, flight: flight, time: time,
                            palette: style.palette, distance: distance,
                            isPlaying: isPlaying, onTogglePlayback: onTogglePlayback)
        case .camera:
            ShotCameraPicker(settings: $camera, original: $original, spatialEdit: $spatialEdit, reviewFrames: $reviewFrames, hasBallTrack: hasBallTrack,
                             strike: strike, time: time, isPlaying: isPlaying,
                             onTogglePlayback: onTogglePlayback,
                             onSeek: onSeek, source: source, frames: frames, pathEnd: flight?.end ?? min(frames.last, strike + 2), onPicking: onPicking)
        }
    }

    /// Every trail at once, four to a row, drawn by the same shaders as the replay.
    private var effectsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 10) {
                ForEach(Array(ShotTrailStyle.allCases.enumerated()), id: \.element) { index, option in
                    effectOption(option, order: index)
                }
            }
            .padding(.horizontal, 16).padding(.top, 4)
            if style != .none {
                HStack(spacing: 10) {
                    Text("Intensity").font(.system(size: 12, weight: .semibold))
                    SessionIntensitySlider(value: $intensity)
                    Text("\(Int((intensity * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText(value: intensity))
                        .frame(width: 38, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .transition(.sessionRise)
            }
        }
    }

    private func effectOption(_ option: ShotTrailStyle, order: Int) -> some View {
        let selected = style == option
        return Button {
            kicks[option, default: 0] += 1
            withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { style = option }
        } label: {
            VStack(spacing: 6) {
                Group {
                    // Every effect shows at once; a pick kicks its ball again.
                    ShotTrailPreview(style: option, kicks: kicks[option, default: 0])
                        .overlay {
                            if option == .none {
                                Image(systemName: "circle.slash").font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(6).background(.black.opacity(0.45), in: .circle)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(EffectIconRenderer.aspect, contentMode: .fit)
                .background(selected ? SessionStyle.mint.opacity(0.1) : .white.opacity(0.04), in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
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
                .sessionKick(kicks[option, default: 0], amount: 0.08)
                Text(option.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .accessibilityLabel(option == .none ? "No effect" : option.title)
        .accessibilityIdentifier("shot-effect-\(option.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A strike at dusk: the real trail shader sweeps from the boot up to a big ball. The ball is
/// kicked across the tile when it appears and again on every pick.
struct ShotTrailPreview: View {
    let style: ShotTrailStyle
    /// Changes on every pick.
    var kicks = 0
    /// When the tile first appears, after this delay the ball is kicked once.
    var kickOnAppear: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kickedAt: Date?

    private static let flight = 0.55

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ShotTileScene()
                TimelineView(.animation(paused: kickedAt == nil)) { timeline in
                    let progress = kickedAt.map { min(1, timeline.date.timeIntervalSince($0) / Self.flight) } ?? 1
                    let eased = 1 - pow(1 - progress, 2.2)
                    ZStack {
                        if style != .none {
                            MetalEffectSurface { pixels in Self.frame(style, size: pixels, progress: eased) }
                        }
                        let center = Self.arc(eased)
                        let radius = Self.radius(eased) * size.height
                        Image("signin-ball").resizable().scaledToFit()
                            .frame(width: radius * 2, height: radius * 2)
                            .rotationEffect(.degrees(eased * 540))
                            .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                            .position(x: center.x * size.width, y: center.y * size.height)
                    }
                }
            }
        }
        .onChange(of: kicks) { _, _ in kick() }
        .task {
            guard let kickOnAppear, !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(kickOnAppear))
            kick()
        }
        .accessibilityHidden(true)
    }

    private func kick() {
        guard !reduceMotion else { return }
        let start = Date()
        kickedAt = start
        Task {
            try? await Task.sleep(for: .seconds(Self.flight + 0.1))
            if kickedAt == start { kickedAt = nil }
        }
    }

    /// From the boot at the lower left, rising toward the goal and curling in. Unit square.
    static func arc(_ t: Double) -> CGPoint {
        let u = 1 - t
        let x = u * u * 0.1 + 2 * u * t * 0.36 + t * t * 0.76
        let y = u * u * 0.94 + 2 * u * t * 0.12 + t * t * 0.38
        return CGPoint(x: x, y: y)
    }

    /// The ball shrinks as it flies away, as a fraction of the tile's height.
    static func radius(_ t: Double) -> CGFloat { CGFloat(0.17 - 0.06 * t) }

    static func frame(_ style: ShotTrailStyle, size: CGSize, progress: Double) -> EffectFrame? {
        guard style != .none, size.width > 0, progress > 0.02 else { return nil }
        let seconds = 0.85 * progress
        func pixel(_ t: Double) -> SIMD2<Float> {
            let p = arc(t)
            return SIMD2(Float(p.x * size.width), Float(p.y * size.height))
        }
        let steps = max(2, Int(seconds * 60))
        let trail = (0...steps).map { step -> SIMD4<Float> in
            let t = progress * Double(step) / Double(steps)
            let p = pixel(t)
            return SIMD4(p.x, p.y, Float(Self.radius(t) * size.height), Float((progress - t) / progress * seconds))
        }
        let head = pixel(progress)
        let before = pixel(max(0, progress - 0.03))
        let ballRadius = Float(Self.radius(progress) * size.height)
        let heading = simd_length(head - before) > 0.01 ? simd_normalize(head - before) : SIMD2<Float>(0.6, -0.8)
        return EffectFrame(size: size, center: head, radius: ballRadius, time: 3, intensity: 1, visibility: 1,
                           velocity: heading * 30, style: style.shaderID, trail: trail)
    }
}

/// A stadium at dusk, for effect tiles: glowing horizon, floodlights, stands, a goal and grass.
struct ShotTileScene: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let horizon = h * 0.62
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(stops: [.init(color: Color(red: 0.03, green: 0.04, blue: 0.13), location: 0),
                                 .init(color: Color(red: 0.16, green: 0.1, blue: 0.3), location: 0.55),
                                 .init(color: Color(red: 0.96, green: 0.48, blue: 0.24), location: 0.98)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
            // Floodlights.
            for light in [CGPoint(x: w * 0.16, y: h * 0.13), CGPoint(x: w * 0.88, y: h * 0.09)] {
                context.fill(Path(ellipseIn: CGRect(x: light.x - h * 0.3, y: light.y - h * 0.3, width: h * 0.6, height: h * 0.6)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.42), .clear]), center: light,
                                                   startRadius: 0, endRadius: h * 0.3))
                // A lamp panel, not a row of dots.
                let lamp = CGRect(x: light.x - h * 0.05, y: light.y - h * 0.02, width: h * 0.1, height: h * 0.04)
                context.fill(Path(roundedRect: lamp, cornerRadius: 1), with: .color(Color(red: 1, green: 0.97, blue: 0.86)))
                var pole = Path()
                pole.move(to: CGPoint(x: light.x, y: lamp.maxY)); pole.addLine(to: CGPoint(x: light.x, y: h * 0.5))
                context.stroke(pole, with: .color(.white.opacity(0.18)), lineWidth: max(0.6, h * 0.008))
            }
            // Stands with a sprinkle of lights.
            let stands = CGRect(x: 0, y: horizon - h * 0.12, width: w, height: h * 0.12)
            context.fill(Path(stands), with: .color(Color(red: 0.04, green: 0.05, blue: 0.09)))
            for index in 0..<Int(w / 3) {
                let x = CGFloat((index * 37) % Int(max(1, w)))
                let y = stands.minY + CGFloat((index * 13) % Int(max(1, stands.height)))
                context.fill(Path(CGRect(x: x, y: y, width: 0.9, height: 0.9)),
                             with: .color(Color(red: 1, green: 0.85, blue: 0.6).opacity(0.5)))
            }
            // The goal, small at the far end.
            var goal = Path()
            goal.move(to: CGPoint(x: w * 0.6, y: horizon + h * 0.01))
            goal.addLine(to: CGPoint(x: w * 0.6, y: horizon - h * 0.12))
            goal.addLine(to: CGPoint(x: w * 0.92, y: horizon - h * 0.12))
            goal.addLine(to: CGPoint(x: w * 0.92, y: horizon + h * 0.01))
            context.stroke(goal, with: .color(.white.opacity(0.85)), lineWidth: max(0.8, h * 0.012))
            // Grass in mown stripes, darker toward the camera.
            let grass = CGRect(x: 0, y: horizon, width: w, height: h - horizon)
            context.fill(Path(grass), with: .linearGradient(
                Gradient(colors: [Color(red: 0.16, green: 0.46, blue: 0.2), Color(red: 0.05, green: 0.2, blue: 0.08)]),
                startPoint: CGPoint(x: 0, y: grass.minY), endPoint: CGPoint(x: 0, y: grass.maxY)))
            for band in 0..<4 where band % 2 == 0 {
                let top = grass.minY + grass.height * CGFloat(band) / 4
                context.fill(Path(CGRect(x: 0, y: top, width: w, height: grass.height / 4)), with: .color(.white.opacity(0.04)))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.35)]), center: CGPoint(x: w / 2, y: h * 0.55),
                startRadius: h * 0.4, endRadius: max(w, h) * 0.8))
        }
    }
}

/// Page swap inside the tray: blurred, slightly smaller and leaning while hidden.
private struct ShotTraySwap: ViewModifier {
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
