#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import UIKit

/// The board shown on the projector, in the looks of
/// benchmarks/wall-targets/grid.html. The outer corners carry the dots the
/// phone calibrates on; a margin keeps them clear of the projector's picture
/// edge, which cheap projectors often crop or blur.
struct WallTargetsBoard: View {
    @ObservedObject var model: WallTargetsModel
    /// Black on the projector (no light); clear when overlaid on the phone's camera view.
    var background: Color = .black
    var onStart: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    var startEnabled = true
    var startStatus: String? = nil
    var showsGameScreens = true
    var runtime: WallRuntimeSample? = nil
    @State private var flashing: UUID?

    static let hitColor = Color(red: 0, green: 1, blue: 0.35)
    /// Space around the board on every side, as a fraction of the screen's width and
    /// height. Keeps the board and its corner dots well inside the projected picture,
    /// clear of the edges a cheap projector blurs, keystones or cuts off.
    static let padding: CGFloat = 0.14

    /// Where the board sits on a screen of `size`; its corners are the calibration dots.
    static func boardRect(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: size.width * padding, dy: size.height * padding)
    }
    /// grid.html's colours.
    private static let htmlGreen = Color(red: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255)
    private static let htmlLine = Color(red: 0xe8 / 255, green: 0xf4 / 255, blue: 1)
    private static let glow = Color(red: 120 / 255, green: 200 / 255, blue: 1)

    var body: some View {
        if showsGameScreens && model.gameScreen != .board {
            WallTargetsGameScreen(model: model, onStart: onStart, onSettings: onSettings,
                                  startEnabled: startEnabled, startStatus: startStatus)
                .overlay(alignment: .bottomLeading) {
                    if let runtime {
                        WallTargetsRuntimeHUD(sample: runtime).padding(.leading, 24).padding(.bottom, 6)
                    }
                }
        } else {
            board
                .overlay(alignment: .topTrailing) {
                    if let onStop {
                        Button(action: onStop) {
                            Label("Stop & Save", systemImage: "stop.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.9), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                        .padding(.top, 6).padding(.trailing, 16)
                        .accessibilityIdentifier("wall.stopAndSave")
                    }
                }
        }
    }

    private var board: some View {
        GeometryReader { geometry in
            let h = geometry.size.height
            let rect = Self.boardRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                background
                if model.calibration != .searching && !model.checkingMapping {
                    if model.style == .metal || model.referenceBox != nil {
                        ForEach(1...6, id: \.self) { box in arenaCell(box, in: rect) }
                    } else {
                        ForEach(1...6, id: \.self) { box in cell(box, in: rect) }
                        gridLines(in: rect)
                            .stroke(model.style == .bright ? Color.white : Self.htmlLine,
                                    lineWidth: (model.style == .bright ? 0.024 : 0.01) * h)
                    }
                }
                if model.checkingMapping && model.mappingDotsVisible {
                    ForEach(WallMappingCheck.points.indices, id: \.self) { index in
                        let point = WallMappingCheck.points[index]
                        Circle().fill(.white)
                            .frame(width: 0.032 * h, height: 0.032 * h)
                            .position(x: rect.minX + point.x / 3 * rect.width,
                                      y: rect.minY + point.y / 2 * rect.height)
                    }
                }
                impactMarkers(in: rect)
                header(height: h).position(x: rect.midX, y: rect.minY / 2)
                HStack(spacing: 12) {
                    if let runtime { WallTargetsRuntimeHUD(sample: runtime) }
                    Text(footer)
                        .font(.system(size: (runtime == nil ? 0.032 : 0.026) * h, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: rect.width)
                .position(x: rect.midX, y: rect.maxY + (h - rect.maxY) / 2 - (runtime == nil ? 0 : 6))
                if model.cornerDots != .hidden {
                    let dot = (model.cornerDots == .large ? 0.10 : 0.032) * h
                    ForEach([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)], id: \.debugDescription) { corner in
                        ZStack {
                            Circle().fill(.black).frame(width: dot * 2, height: dot * 2)
                            Circle().fill(.white).frame(width: dot, height: dot)
                        }.position(corner)
                    }
                }
                if model.calibration == .searching {
                    // Shown in both blink phases, so it cancels out of the camera's dot search.
                    Text(model.isFocusing ? "Step aside · focusing on the wall" : "Step aside · finding the corners")
                        .font(.system(size: 0.07 * h, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 0.04 * h).padding(.vertical, 0.02 * h)
                        .background(.white, in: Capsule())
                        .position(x: rect.midX, y: rect.midY)
                }
                if let countdown = model.countdown {
                    Text("\(countdown)")
                        .font(.system(size: h * 0.25, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(h * 0.035)
                        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: h * 0.035))
                        .position(x: rect.midX, y: rect.midY)
                }
                if model.showingGo {
                    Text("GO")
                        .font(.system(size: h * 0.18, weight: .black, design: .rounded))
                        .foregroundStyle(Self.metalCyan)
                        .padding(.horizontal, h * 0.06).padding(.vertical, h * 0.015)
                        .background(.black.opacity(0.9), in: Capsule())
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                if model.calibration == .failed || model.referenceFailed || model.mappingFailed {
                    VStack(spacing: h * 0.025) {
                        Text(model.mappingFailed ? "BOARD CHECK NEEDS A RETRY" : model.focusFailed ? "FOCUS NEEDS A RETRY" : (model.referenceFailed ? "REPEAT BALL SETUP" : "ALIGN THE BOARD")).font(.system(size: h * 0.06, weight: .heavy))
                        Text(model.mappingFailed ? "Keep the phone still and the whole board visible" : model.focusFailed ? "Keep the phone still and stand clear of the wall" : (model.referenceFailed ? "Touch the wall with the same ball at each target" : "Keep all four white dots in the camera"))
                            .font(.system(size: h * 0.035, weight: .medium))
                        Text("Tap the phone to retry")
                            .font(.system(size: h * 0.04, weight: .bold))
                    }
                    .foregroundStyle(.white).padding(h * 0.04)
                    .background(.black.opacity(0.95), in: RoundedRectangle(cornerRadius: h * 0.03))
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: model.lastHit?.id) { _, id in
            flashing = id
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if flashing == id { withAnimation(.easeOut(duration: 0.3)) { flashing = nil } }
            }
        }
    }

    private var footer: String {
        if model.checkingMapping { return "Stand aside · keep the whole board clear" }
        if model.mappingFailed { return model.notice ?? "Tap the phone to retry the board check" }
        if model.sessionEnded {
            return model.recordingState.message + " · long-press for settings"
        }
        if model.contactPreview != nil {
            return model.alignmentStatus == .obscured
                ? "Checking shot · keep the corner dots visible" : "Checking shot…"
        }
        return (model.referenceBox == nil && model.calibration == .ready ? model.alignmentNotice : nil)
            ?? model.borderlineNotice ?? model.notice
            ?? (model.isPlaying ? "\(6 - model.boxesHit.count) left · any order · Stop & Save on the phone" : "Stop & Save on the phone")
    }

    private func impactMarkers(in rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                WallTargetsImpactMarker(number: index + 1, latest: hit.id == model.lastHit?.id,
                                        diameter: rect.height * 0.078)
                    .position(x: hit.u / 3 * rect.width, y: hit.v / 2 * rect.height)
            }
            if let contact = model.contactPreview {
                // A hollow white ring acknowledges measured contact. Only a
                // confirmed score gets the permanent numbered mark and chime.
                ZStack {
                    Circle().stroke(.black.opacity(0.85), lineWidth: rect.height * 0.014)
                    Circle().stroke(.white, style: StrokeStyle(lineWidth: rect.height * 0.006,
                                                              dash: [rect.height * 0.012, rect.height * 0.008]))
                    Circle().fill(.white).frame(width: rect.height * 0.012)
                }
                .frame(width: rect.height * 0.10, height: rect.height * 0.10)
                .position(x: contact.u / 3 * rect.width, y: contact.v / 2 * rect.height)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    private func header(height h: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            if model.isPlaying {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: h * 0.012) {
                        Text("CLEAR THE WALL")
                            .font(.system(size: h * 0.04, weight: .black, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                        HStack(spacing: h * 0.01) {
                            ForEach(1...6, id: \.self) { box in
                                Capsule().fill(model.boxesHit.contains(box) ? Self.metalGold : .white.opacity(0.25))
                                    .frame(width: h * 0.055, height: h * 0.009)
                            }
                            Text("\(model.boxesHit.count)/6")
                                .font(.system(size: h * 0.025, weight: .bold, design: .rounded))
                                .fixedSize()
                        }
                    }
                    Spacer(minLength: h * 0.08)
                    VStack(alignment: .trailing, spacing: h * 0.002) {
                        Text(model.timerStatus)
                            .font(.system(size: h * 0.019, weight: .bold))
                            .foregroundStyle(model.alignmentStatus == .ready ? Self.metalCyan : Self.metalGold)
                        Text(String(format: "%.1f s", model.elapsed(at: timeline.date)))
                            .font(.system(size: h * 0.055, weight: .black, design: .rounded).monospacedDigit())
                            .fixedSize()
                    }
                }
                .foregroundStyle(.white)
                .frame(width: h * 1.1, height: h * 0.10)
            } else {
            VStack(spacing: h * 0.008) {
                Text(model.checkingMapping ? "CHECKING THE WHOLE BOARD" : model.referenceBox.map { "SETUP · TOUCH WALL AT \($0)" }
                     ?? (model.clearedAt != nil ? "WALL CLEARED!" : "CLEAR THE WALL"))
                    .font(.system(size: h * 0.046, weight: .black, design: .rounded))
                HStack(spacing: h * 0.06) {
                    if model.checkingMapping {
                        Text("Keep the phone still · scoring is off")
                    } else if let box = model.referenceBox {
                        Text("\(box) / 6 · scoring is off")
                    } else {
                        Text("\(model.boxesHit.count) / 6")
                        let seconds = model.elapsed(at: timeline.date)
                        Text("\(model.timerStatus) · " + (model.clearedAt != nil
                            ? String(format: "%.1f s", seconds)
                            : String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)))
                    }
                }
                .font(.system(size: h * 0.035, weight: .semibold, design: .rounded).monospacedDigit())
            }.foregroundStyle(model.clearedAt != nil ? Self.metalGold : .white)
            }
        }
    }

    /// A static board leaves the GPU free for detection; only hit feedback animates.
    private func arenaCell(_ box: Int, in rect: CGRect) -> some View {
        let frame = metalFrame(box, in: rect), unit = rect.height
        let (hit, flash) = metalState(box)
        let reference = model.referenceBox == box
        let tint = reference ? Self.metalGold : (flash ? Color.white : (hit ? Self.metalGold : Self.metalCyan))
        return ZStack {
            RoundedRectangle(cornerRadius: unit * 0.018)
                .fill(tint.opacity(flash ? 0.65 : 0.14))
            RoundedRectangle(cornerRadius: unit * 0.018)
                .strokeBorder(tint, lineWidth: unit * 0.012)
                .shadow(color: tint.opacity(0.65), radius: unit * 0.014)
            Text(hit ? "✓" : "\(box)")
                .font(.system(size: unit * 0.24, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
            if reference {
                Circle().stroke(.white.opacity(0.25), lineWidth: unit * 0.012)
                    .frame(width: unit * 0.36, height: unit * 0.36)
                Circle().trim(from: 0, to: model.referenceProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: unit * 0.018, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: unit * 0.36, height: unit * 0.36)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .opacity(model.referenceBox == nil || reference ? 1 : 0.30)
    }

    private func gridLines(in rect: CGRect) -> Path {
        Path { path in
            for i in 0...3 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for j in 0...2 {
                let y = rect.minY + rect.height * CGFloat(j) / 2
                path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }

    private func cell(_ box: Int, in rect: CGRect) -> some View {
        let w = rect.width / 3, h = rect.height / 2
        let frame = CGRect(x: rect.minX + CGFloat((box - 1) % 3) * w, y: rect.minY + CGFloat((box - 1) / 3) * h,
                           width: w, height: h)
        let look = look(box: box, hit: model.boxesHit.contains(box),
                        flash: flashing != nil && model.lastHit?.box == box)
        let unit = rect.height
        return ZStack {
            if look.lit {
                // A filled box with a brighter centre and a glowing edge reads from across the room.
                Rectangle().fill(RadialGradient(colors: [look.fill.mix(with: .white, by: 0.35), look.fill],
                                                center: .center, startRadius: 0, endRadius: max(w, h) * 0.7))
                Rectangle().strokeBorder(look.fill.mix(with: .white, by: 0.6), lineWidth: unit * 0.02)
                    .blur(radius: unit * 0.012)
            } else {
                Rectangle().fill(look.fill)
            }
            Text(look.symbol)
                .font(.system(size: unit * 0.3, weight: .heavy))
                .foregroundStyle(look.number)
                .shadow(color: look.glow, radius: unit * 0.015)
                .shadow(color: look.glow.opacity(0.7), radius: unit * 0.04)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
    }

    /// Metal: tuned for a light, warm wall. A projector can only add light, so
    /// the board stays in bright, saturated tones and black appears only in the
    /// gaps (where it reads as bare wall). Electric cyan is the complement of a
    /// beige wall, so remaining targets pop; hit boxes turn a calmer warm gold.
    static let metalCyan = Color(red: 0, green: 0.86, blue: 1)
    static let metalGold = Color(red: 1, green: 0.78, blue: 0.2)

    private func metalFrame(_ box: Int, in rect: CGRect) -> CGRect {
        let gap = rect.height * 0.022, w = rect.width / 3, h = rect.height / 2
        return CGRect(x: rect.minX + CGFloat((box - 1) % 3) * w, y: rect.minY + CGFloat((box - 1) / 3) * h,
                      width: w, height: h).insetBy(dx: gap / 2, dy: gap / 2)
    }

    private func metalState(_ box: Int) -> (hit: Bool, flash: Bool) {
        (model.boxesHit.contains(box), flashing != nil && model.lastHit?.box == box)
    }

    /// The box body and its glow, from the `wallTargetBox` Metal shader.
    private func metalBox(_ box: Int, in rect: CGRect, time: Float) -> some View {
        let unit = rect.height, frame = metalFrame(box, in: rect), pad = unit * 0.05
        let (hit, flash) = metalState(box)
        let size = CGSize(width: frame.width + 2 * pad, height: frame.height + 2 * pad)
        return Rectangle().fill(.white)
            .frame(width: size.width, height: size.height)
            .colorEffect(ShaderLibrary.wallTargetBox(
                .float2(size), .float(pad), .float(unit * 0.025),
                .color(flash ? .white : (hit ? Self.metalGold : Self.metalCyan)),
                .float(time), .float(flash ? 1 : 0), .float(unit * 0.012)))
            .blendMode(.plusLighter)
            .position(x: frame.midX, y: frame.midY)
    }

    /// A dark cut-out number with a white halo stays crisp on a bright fill.
    private func metalLabel(_ box: Int, in rect: CGRect) -> some View {
        let unit = rect.height, frame = metalFrame(box, in: rect)
        let (hit, flash) = metalState(box)
        return Text(hit && !flash ? "✓" : "\(box)")
            .font(.system(size: unit * 0.3, weight: .black, design: .rounded))
            .foregroundStyle(.black)
            .shadow(color: .white, radius: unit * 0.006)
            .shadow(color: .white.opacity(0.8), radius: unit * 0.012)
            .position(x: frame.midX, y: frame.midY)
    }

    private struct Look {
        var fill: Color, lit: Bool, number: Color, glow: Color, symbol: String
    }

    /// The unhit fill of a box in a style, for the phone overlay.
    static func colour(for box: Int, style: WallBoardStyle) -> Color {
        switch style {
        case .metal: metalCyan
        case .green, .glow: htmlGreen
        case .neon: neon[box - 1]
        case .bright: hitColor
        }
    }

    /// Neon box colours, saturated so they survive a washed-out wall.
    private static let neon: [Color] = [
        Color(red: 0, green: 0.9, blue: 1), Color(red: 0.2, green: 1, blue: 0.4), Color(red: 1, green: 0.9, blue: 0.1),
        Color(red: 1, green: 0.5, blue: 0.1), Color(red: 1, green: 0.2, blue: 0.8), Color(red: 0.3, green: 0.5, blue: 1)]

    private func look(box: Int, hit: Bool, flash: Bool) -> Look {
        let number = "\(box)"
        if flash { return Look(fill: .white, lit: false, number: .black, glow: .clear, symbol: number) }
        switch model.style {
        // Boxes stay filled like grid.html, so the board stays visible on the wall;
        // a hit turns its box a bright pale tint with a tick instead of going dark.
        case .green, .metal:   // metal draws its own cells; this only keeps the switch complete
            return hit ? Look(fill: Self.htmlGreen.mix(with: .white, by: 0.7), lit: true,
                              number: Self.htmlGreen.mix(with: .black, by: 0.45), glow: .clear, symbol: "✓")
                       : Look(fill: Self.htmlGreen, lit: true, number: .white, glow: Self.glow, symbol: number)
        case .neon:
            let colour = Self.neon[box - 1]
            return hit ? Look(fill: colour.mix(with: .white, by: 0.7), lit: true,
                              number: colour.mix(with: .black, by: 0.5), glow: .clear, symbol: "✓")
                       : Look(fill: colour, lit: true, number: .black, glow: .clear, symbol: number)   // dark cut-out reads best on bright fills
        case .glow:
            return hit ? Look(fill: Self.htmlGreen, lit: true, number: .white, glow: Self.glow, symbol: number)
                       : Look(fill: .black, lit: false, number: Color(white: 0.96), glow: Self.glow, symbol: number)
        case .bright:
            return hit ? Look(fill: Self.hitColor, lit: false, number: .black, glow: .clear, symbol: number)
                       : Look(fill: .black, lit: false, number: .white, glow: .clear, symbol: number)
        }
    }

    private func marker(_ number: Int, at point: CGPoint, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.red)
            Circle().stroke(.white, lineWidth: size * 0.12)
            Text("\(number)").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .position(point)
    }
}

/// Numbered contact point. Only the arrival pulse animates; the ring remains
/// fixed at the measured board coordinates for the rest of the session.
private struct WallTargetsImpactMarker: View {
    let number: Int
    let latest: Bool
    let diameter: CGFloat
    @State private var expanded = false

    var body: some View {
        ZStack {
            if latest {
                Circle().stroke(.white, lineWidth: diameter * 0.08)
                    .scaleEffect(expanded ? 2.4 : 1)
                    .opacity(expanded ? 0 : 0.9)
            }
            Circle().fill(.black.opacity(0.9))
            Circle().stroke(.white, lineWidth: diameter * 0.075)
            Circle().stroke(Color(red: 1, green: 0.3, blue: 0.15), lineWidth: diameter * 0.075)
                .padding(diameter * 0.12)
            Text("\(number)")
                .font(.system(size: diameter * 0.42, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Impact \(number)")
        .task { withAnimation(.easeOut(duration: 0.65)) { expanded = true } }
    }
}

/// Window on the AirPlay / HDMI screen. While the phone mirrors to the
/// projector, iOS hands this app a non-interactive external-display scene and
/// shows this window instead of a copy of the phone screen.
final class WallTargetsProjectorScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WallTargetsBoard(model: .shared))
        window.isHidden = false
        self.window = window
        WallTargetsModel.shared.setProjectorConnected(true)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        WallTargetsModel.shared.setProjectorConnected(false)
    }
}

/// Routes external-display scenes to the projector window and lets the wall
/// screen lock itself to landscape while the rest of the debug app stays portrait.
final class WallTargetsAppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = WallTargetsProjectorScene.self
        }
        return configuration
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }

    @MainActor
    static func lock(_ mask: UIInterfaceOrientationMask) {
        orientations = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.session.role == .windowApplication {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
#endif
