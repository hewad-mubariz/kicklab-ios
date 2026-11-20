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
    var onPenalties: (() -> Void)? = nil
    var onChallenge: ((GoalChallengeMode) -> Void)? = nil
    var startEnabled = true
    var startStatus: String? = nil
    var showsGameScreens = true
    var runtime: WallRuntimeSample? = nil
    @State private var flashing: UUID?
    @State private var bursts: [WallTargetsModel.Hit] = []
    @State private var finishingBurst = false

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
        Group {
            if showsGameScreens && model.gameScreen != .board && !finishingBurst {
                WallTargetsGameScreen(model: model, onStart: onStart, onSettings: onSettings,onPenalties:onPenalties,onChallenge:onChallenge,
                                      startEnabled: startEnabled, startStatus: startStatus)
            } else {
                board
            }
        }
        .onChange(of: model.lastHit?.id) { _, id in
            flashing = id
            guard let hit = model.lastHit else { bursts = []; finishingBurst = false; return }
            if model.game == .brickBlast {
                bursts.append(hit)
                if bursts.count > 3 { bursts.removeFirst(bursts.count - 3) }
                finishingBurst = model.clearedAt != nil
            }
            if model.game.isArcade { finishingBurst = model.clearedAt != nil }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(model.game == .brickBlast ? WallBrickExplosion.duration : model.game.isParty ? 2.5 : model.game.isArcade ? 0.7 : 0.35))
                bursts.removeAll { $0.id == id }
                if flashing == id { flashing = nil; finishingBurst = false }
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
                    if model.referenceBox == WallReferenceCollector.wallCentre {
                        centreReference(in: rect)
                    } else if model.game.isArcade {
                        if model.wallReference != nil {
                            WallArcadeBoard(model: model)
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    } else if model.game == .brickBlast, model.wallReference != nil, model.referenceBox == nil {
                        ForEach(model.game.layout.targets) { target in
                            let box = target.id
                            let frame = target.screenFrame(in: rect)
                            WallBrickTile(health: model.remainingHealth(for: box),
                                          initialHealth: model.game.initialHealth(for: box),
                                          seed: box, impact: brickImpact(box, frame: frame, board: rect))
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    } else if model.game == .brickBlast, model.wallReference == nil, model.referenceBox == nil {
                        Color.clear // Setup geometry is independent of the game targets.
                    } else if model.style == .metal || model.referenceBox != nil {
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
                if model.game == .brickBlast {
                    brickBursts(in: rect)
                }
                if !model.game.isArcade { impactMarkers(in: rect) }
                header(height: h, width: rect.width * 0.90).position(x: rect.midX, y: rect.minY / 2)
                VStack(spacing: h * 0.008) {
                    Text(footer)
                        .font(.system(size: (model.game == .crossCircle && model.isPlaying ? 0.046 :
                            (model.game == .memoryStrike || model.game.isParty) && model.isPlaying ? 0.043 : 0.034) * h,
                                      weight: model.game == .crossCircle ? .black : .bold, design: .rounded))
                        .foregroundStyle(model.borderlineNotice != nil ? Self.metalGold : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let runtime, runtime.thermalState >= 2 {
                        Text(runtime.shouldEndRound ? "PHONE HOT · SAVING" : "PHONE HOT · FINISH & COOL")
                            .font(.system(size: h * 0.035, weight: .heavy, design: .rounded))
                            .foregroundStyle(Self.metalGold)
                    }
                }
                .frame(width: rect.width * 0.92)
                .position(x: rect.midX, y: rect.maxY + (h - rect.maxY) / 2)
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
                if model.showingGo && !model.game.isArcade {
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
                        Text(model.mappingFailed ? "Keep the phone still and the whole board visible" : model.focusFailed ? "Keep the phone still and stand clear of the wall" : (model.referenceFailed ? "Touch the wall with the ball at the centre ring" : "Keep all four white dots in the camera"))
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
    }

    private func brickBursts(in rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(bursts) { hit in
                let localBoard = CGRect(origin: .zero, size: rect.size)
                let bricks = hit.brickDamage.compactMap { damage -> WallBrickExplosion.Brick? in
                    guard let target = model.game.layout.target(damage.id) else { return nil }
                    return .init(id: damage.id, frame: target.screenFrame(in: localBoard), shattered: damage.shattered)
                }
                let footprint = hit.footprint ?? .preview
                let radius = sqrt(abs(footprint.determinant) * rect.width / 3 * rect.height / 2)
                WallBrickExplosion(bricks: bricks,
                    origin: CGPoint(x: hit.u / 3 * rect.width, y: hit.v / 2 * rect.height),
                    ballRadius: radius, strength: WallImpactMotion.strength(for: hit.approachSpeed))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped() // Board-level limit; fragments can leave a brick but not the tracking area.
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    private var footer: String {
        if model.calibration == .searching { return "SETUP 1/3 · finding four corners · stand aside" }
        if model.checkingMapping { return "Stand aside · keep the whole board clear" }
        if model.mappingFailed { return model.notice ?? "Tap the phone to retry the board check" }
        if model.sessionEnded {
            return model.recordingState.message + " · long-press for settings"
        }
        if model.contactPreview != nil {
            return model.alignmentStatus == .obscured
                ? "Checking shot · keep the corner dots visible" : "Checking shot…"
        }
        if !model.isPlaying, model.wallReference == nil, model.calibration == .ready,
           model.referenceBox == nil {
            return "SETUP 1/3 · confirming the four dots · stand aside"
        }
        return (model.referenceBox == nil && model.calibration == .ready ? model.alignmentNotice : nil)
            ?? model.borderlineNotice ?? model.notice
            ?? (model.isPlaying ? (model.game.isArcade ? arcadeInstruction : model.game == .brickBlast
                ? "Smash the wall · hit a joint to break more"
                : "\(6 - model.boxesHit.count) left · any order · long-press to stop and save") : "Long-press to stop and save")
    }

    private var arcadeInstruction: String {
        if model.game == .fourInRow { return "HIT A COLUMN · CONNECT FOUR" }
        if model.game == .territoryDuel { return "CLAIM OR STEAL · EVERY SHOT COUNTS" }
        if model.game == .copyMyShot { return "SET A SPOT · MATCH INSIDE THE GOLD RING" }
        if model.game == .crossCircle { return "HIT AN EMPTY SQUARE" }
        if model.game == .goalDuel { return "AIM PAST THE ROBOT · INSIDE THE POSTS" }
        if let memory = model.memory {
            switch memory.phase {
            case .watching: return "WAIT · NO KICKS YET"
            case .recalling: return "SAME ORDER · ONE KICK PER SYMBOL"
            case .interlude: return "WAIT FOR YOUR TURN"
            case .finished: return memory.won ? "Five rounds remembered!" : "Three lives used · try again"
            }
        }
        return model.meteors?.phase == .interlude ? "City protected · next wave incoming"
            : "Hit the glowing rocks before they reach the city"
    }

    private func impactMarkers(in rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                if model.game == .brickBlast {
                    Circle().stroke(Self.metalCyan.opacity(hit.id == model.lastHit?.id ? 0.85 : 0.35),
                                    lineWidth: rect.height * 0.003)
                        .frame(width: rect.height * 0.027, height: rect.height * 0.027)
                        .position(x: hit.u / 3 * rect.width, y: hit.v / 2 * rect.height)
                } else {
                    WallTargetsImpactMarker(number: index + 1, latest: hit.id == model.lastHit?.id,
                                            diameter: rect.height * 0.078)
                        .position(x: hit.u / 3 * rect.width, y: hit.v / 2 * rect.height)
                }
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

    private func header(height h: CGFloat, width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            if model.game.isParty && (model.isPlaying || model.sessionEnded) {
                WallPartyHUD(model: model, height: h).frame(width: width, height: h * 0.10)
            } else if model.game.isArcade && (model.isPlaying || model.sessionEnded) {
                WallArcadeHUD(model: model, height: h).frame(width: width, height: h * 0.10)
            } else if model.isPlaying && model.game == .brickBlast {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: h * 0.002) {
                        Text("SCORE").font(.system(size: h * 0.025, weight: .bold).width(.condensed))
                        Text("\(model.brickScore)").font(.system(size: h * 0.065, weight: .heavy).width(.condensed).monospacedDigit())
                            .foregroundStyle(Self.metalCyan)
                    }
                    Spacer()
                    VStack(spacing: h * 0.005) {
                        Text("BRICK BLAST").font(.system(size: h * 0.024, weight: .bold).width(.condensed))
                        Text(model.timerStatus + " · " + String(format: "%.1f s", model.elapsed(at: timeline.date)))
                            .font(.system(size: h * 0.024, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: h * 0.002) {
                        Text("\(model.game.targetCount - model.clearedBoxes.count)")
                            .font(.system(size: h * 0.065, weight: .heavy).width(.condensed).monospacedDigit())
                            .foregroundStyle(Self.metalGold)
                        Text("BRICKS LEFT").font(.system(size: h * 0.025, weight: .bold).width(.condensed))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: width, height: h * 0.10)
            } else if model.isPlaying {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: h * 0.012) {
                        Text(model.game.title.uppercased())
                            .font(.system(size: h * 0.035, weight: .black, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                        HStack(spacing: h * 0.01) {
                            ForEach(model.game.targetIDs, id: \.self) { box in
                                Capsule().fill(model.clearedBoxes.contains(box) ? Self.metalGold : .white.opacity(0.25))
                                    .frame(width: h * (model.game == .brickBlast ? 0.024 : 0.055), height: h * 0.009)
                            }
                            Text("\(model.clearedBoxes.count)/\(model.game.targetCount)")
                                .font(.system(size: h * 0.025, weight: .bold, design: .rounded))
                                .fixedSize()
                        }
                    }
                    Spacer(minLength: h * 0.04)
                    if model.game == .brickBlast {
                        HStack(alignment: .firstTextBaseline, spacing: h * 0.012) {
                            Text("\(model.game.targetCount - model.clearedBoxes.count)")
                                .font(.system(size: h * 0.075, weight: .black, design: .rounded).monospacedDigit())
                            Text("LEFT")
                                .font(.system(size: h * 0.028, weight: .black, design: .rounded))
                        }
                        .foregroundStyle(Self.metalGold)
                        .accessibilityLabel("\(model.game.targetCount - model.clearedBoxes.count) bricks left")
                        Spacer(minLength: h * 0.04)
                    }
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
                .frame(width: width, height: h * 0.10)
            } else {
            VStack(spacing: h * 0.008) {
                Text(model.checkingMapping ? "\(model.game.title.uppercased()) · SETUP 2/3" : model.referenceBox.map { $0 == WallReferenceCollector.wallCentre ? "SETUP 3/3 · ONE BALL HOLD" : "SETUP 3/3 · TOUCH WALL AT \($0)" }
                     ?? (model.clearedAt != nil ? "WALL CLEARED!" : model.game.title.uppercased() + (model.isPlaying ? "" : " · SETUP")))
                    .font(.system(size: h * 0.046, weight: .black, design: .rounded))
                HStack(spacing: h * 0.06) {
                    if model.checkingMapping {
                        Text("Keep the phone still · scoring is off")
                    } else if let box = model.referenceBox {
                        Text(box == WallReferenceCollector.wallCentre ? "Touch the wall at the ring · hold still" : "\(box) / 6 · scoring is off")
                    } else {
                        if !model.isPlaying, model.wallReference == nil, model.game != .clearTheWall {
                            Text("Check the wall · one ball hold · then play")
                        } else {
                            Text("\(model.clearedBoxes.count) / \(model.game.targetCount)")
                            let seconds = model.elapsed(at: timeline.date)
                            Text("\(model.timerStatus) · " + (model.clearedAt != nil
                                ? String(format: "%.1f s", seconds)
                                : String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)))
                        }
                    }
                }
                .font(.system(size: h * 0.035, weight: .semibold, design: .rounded).monospacedDigit())
            }.foregroundStyle(model.clearedAt != nil ? Self.metalGold : .white)
            }
        }
    }

    /// One calibration anchor, unrelated to any game's target count or layout.
    private func centreReference(in rect: CGRect) -> some View {
        let diameter = rect.height * 0.36
        return ZStack {
            Circle().fill(.black)
            Circle().stroke(Self.metalCyan, lineWidth: rect.height * 0.012)
            Circle().trim(from: 0, to: model.referenceProgress)
                .stroke(.white, style: StrokeStyle(lineWidth: rect.height * 0.025, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "soccerball")
                .font(.system(size: diameter * 0.35, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel("Hold the ball against the wall at this ring")
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

    private func brickImpact(_ box: Int, frame: CGRect, board: CGRect) -> CGPoint {
        guard let hit = model.hits.last(where: { $0.brickDamage.contains { $0.id == box } }) else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, (board.minX + hit.u / 3 * board.width - frame.minX) / frame.width)),
                       y: min(1, max(0, (board.minY + hit.v / 2 * board.height - frame.minY) / frame.height)))
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
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        WallTargetsModel.shared.setProjectorConnected(true)
        window.rootViewController = UIHostingController(rootView: WallGamesProjectorRoot())
        self.window = window
        // Keep input and accessibility focus on the phone.
        window.isHidden = false
        NotificationCenter.default.addObserver(self, selector:#selector(displayModeChanged(_:)),
            name:UIScreen.modeDidChangeNotification, object:scene.screen)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let scene=scene as? UIWindowScene else { return }
        // Some receivers cannot change mode until the scene owns a visible window.
        selectDisplayMode(scene)
        resizeToDisplay(scene)
    }

    @objc private func displayModeChanged(_ notification:Notification) {
        guard let scene=window?.windowScene else { return }
        resizeToDisplay(scene)
    }

    private func resizeToDisplay(_ scene:UIWindowScene) {
        window?.frame=scene.screen.bounds
        NSLog("WALL_PROJECTOR_GEOMETRY %@", "scene=\(scene.effectiveGeometry.coordinateSpace.bounds) screen=\(scene.screen.bounds)")
    }

    private func selectDisplayMode(_ scene: UIWindowScene) {
        // Some outputs prefer a legacy 720×480 mode even when their display is
        // 1080p. Select an advertised mode, bounded to 1080p for the phone GPU.
        let modes=scene.screen.availableModes.filter { $0.size.width*$0.size.height <= 1920*1080 }
        if let mode=modes.max(by:{ $0.size.width*$0.size.height < $1.size.width*$1.size.height })
            ?? scene.screen.preferredMode { scene.screen.currentMode=mode }
        NSLog("WALL_PROJECTOR %@", "scene=\(scene.effectiveGeometry.coordinateSpace.bounds) screen=\(scene.screen.bounds) current=\(String(describing:scene.screen.currentMode?.size)) modes=\(scene.screen.availableModes.map(\.size))")
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        resizeToDisplay(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        NotificationCenter.default.removeObserver(self,name:UIScreen.modeDidChangeNotification,object:nil)
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
        let configuration = UISceneConfiguration(
            name: session.role == .windowExternalDisplayNonInteractive ? "Wall Projector":nil,
            sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.sceneClass = UIWindowScene.self
            configuration.delegateClass = WallTargetsProjectorScene.self
        }
        return configuration
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if window?.windowScene?.session.role == .windowExternalDisplayNonInteractive { return .all }
        return Self.orientations
    }

    @MainActor
    static func lock(_ mask: UIInterfaceOrientationMask) {
        orientations = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.session.role == .windowApplication {
            // A presented guide owns the active orientation decision. Updating only
            // the root leaves its presented controller's cached portrait mask.
            var controller=scene.keyWindow?.rootViewController
            while let current=controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller=current.presentedViewController
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                NSLog("WALL_ORIENTATION %@", error.localizedDescription)
            }
        }
    }

}
#endif
