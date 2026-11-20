#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

/// The phone and external display share the same game presentation. Only the
/// phone supplies actions; the wall tells the player where to start the round.
struct WallTargetsGameScreen: View {
    @ObservedObject var model: WallTargetsModel
    var onStart: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPenalties: (() -> Void)? = nil
    var onChallenge: ((GoalChallengeMode) -> Void)? = nil
    var startEnabled = true
    var startStatus: String?

    private let cyan = WallTargetsBoard.metalCyan
    private let gold = WallTargetsBoard.metalGold
    private var results: Bool { model.gameScreen == .results }
    private var cleared: Bool { model.clearedAt != nil }

    var body: some View {
        GeometryReader { geometry in
            let h = geometry.size.height
            let w = geometry.size.width * 0.82
            VStack(alignment: .leading, spacing: h * (onChallenge == nil ? 0.035:0.025)) {
                VStack(alignment: .leading, spacing: h * 0.012) {
                    Text("KICKLAB  /  WALL GAMES")
                        .tracking(h * 0.003)
                    gameSelector(height: h)
                }
                .font(.system(size: h * 0.022, weight: .bold))
                .foregroundStyle(cyan)

                HStack(alignment: .center, spacing: w * 0.07) {
                    if results && model.game.isParty { partyResults(height: h) }
                    else if results { resultDetails(height: h) }
                    else { introduction(height: h) }
                    VStack(alignment: .leading, spacing: h * 0.022) {
                        Text(results ? (model.game.isArcade ? "YOUR ROUND" : "YOUR HIT MAP") : mapTitle)
                            .font(.system(size: h * 0.023, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.7))
                        targetMap(height: h)
                            .aspectRatio(1.5, contentMode: .fit)
                        Text(results ? (model.game.isArcade ? model.game.instructions : "Numbered marks show confirmed contacts.") : model.game.instructions)
                            .font(.system(size: h * 0.025, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: w * 0.40)
                }
                .frame(height: h * (onChallenge == nil ? 0.43:0.37))

                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                HStack(spacing: h * 0.025) {
                    primaryAction(height: h)
                    if let onSettings {
                        Button(action: onSettings) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: h * 0.03, weight: .bold))
                                .frame(width: max(44, h * 0.09), height: max(44, h * 0.09))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: h * 0.016))
                        .accessibilityLabel("Settings and recordings")
                    }
                    Spacer(minLength: h * 0.03)
                    VStack(alignment: .trailing, spacing: h * 0.006) {
                        Text(results ? model.recordingState.message : "Fixed phone · clear corner dots")
                            .foregroundStyle(results && model.recordingState == .saved ? gold : .white)
                        Text(startStatus ?? (results ? "Setup and alignment pauses excluded from time." : "Setup first, then 3 · 2 · 1 · GO"))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .font(.system(size: h * 0.022, weight: .medium))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: w)
            .position(x: geometry.size.width / 2, y: h / 2)
        }
        .background(.black)
        .ignoresSafeArea()
    }

    private func gameSelector(height h: CGFloat) -> some View {
        VStack(spacing: h * 0.012) {
            if onStart != nil {
                ForEach(0..<2) { row in
                    HStack(spacing: h * 0.015) {
                        ForEach(WallGame.allCases.filter { $0.isParty == (row == 1) }) { game in
                            Button { model.selectGame(game) } label: {
                                Text(game.title)
                                    .font(.system(size: h * 0.028, weight: .bold))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                    .padding(.horizontal, h * 0.012)
                                    .frame(maxWidth: .infinity).frame(minHeight: 44)
                                    .background(model.game == game ? cyan.opacity(0.18) : .white.opacity(0.04),
                                                in: RoundedRectangle(cornerRadius: h * 0.012))
                                    .overlay(RoundedRectangle(cornerRadius: h * 0.012)
                                        .stroke(model.game == game ? cyan : .white.opacity(0.2), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(model.game == game ? cyan : .white.opacity(0.75))
                            .disabled(!model.canStartGame)
                            .accessibilityIdentifier("wall-game-" + game.rawValue)
                            .accessibilityAddTraits(model.game == game ? .isSelected : [])
                        }

                    }
                }
                HStack(spacing:h*0.015) {
                    if let onChallenge {
                        ForEach(GoalChallengeMode.allCases) { mode in
                            challengeButton(mode.title,identifier:mode.rawValue,height:h) { onChallenge(mode) }
                        }
                    }
                    if let onPenalties {
                        challengeButton("Virtual Penalties",identifier:"virtual-penalties",height:h,action:onPenalties)
                    }
                }
            } else { Text(model.game.title.uppercased()) }
        }
    }

    private func challengeButton(_ title: String,identifier: String,height h: CGFloat,action: @escaping () -> Void) -> some View {
        Button(action:action) {
            Text(title).font(.system(size:h*0.028,weight:.bold))
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth:.infinity).frame(minHeight:44)
                .background(gold.opacity(0.08),in:RoundedRectangle(cornerRadius:h*0.012))
                .overlay(RoundedRectangle(cornerRadius:h*0.012).stroke(gold.opacity(0.5),lineWidth:1))
        }.buttonStyle(.plain).foregroundStyle(gold)
            .disabled(!model.canStartGame || model.isPlaying || !startEnabled)
            .accessibilityIdentifier("wall-game-" + identifier)
    }

    private func introduction(height h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.026) {
            Text(model.game.headline)
                .font(.system(size: h * 0.102, weight: .black, design: .rounded))
                .lineSpacing(-h * 0.014)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.75)
            Text(model.game.subtitle)
                .font(.system(size: h * 0.031, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Label(model.game.isParty ? "2 PLAYERS · 1 BALL · TAKE TURNS" : model.game.isArcade
                  ? (model.bestArcadeScore > 0 ? "BEST ON THIS PHONE  \(model.bestArcadeScore)" : "Set your first high score")
                  : model.bestClearTime.map { "BEST ON THIS PHONE  " + time($0) } ?? "Set your first personal best",
                  systemImage: "trophy.fill")
                .font(.system(size: h * 0.026, weight: .bold, design: .rounded))
                .foregroundStyle(gold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func partyResults(height h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.022) {
            Text(model.partyResultTitle)
                .font(.system(size: h * 0.050, weight: .black, design: .rounded))
                .foregroundStyle(model.partyWinner?.tint ?? gold)
            if let state = model.goalDuel {
                Text("\(state.goals(.one)) – \(state.goals(.two))")
                    .font(.system(size: h * 0.13, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text("PLAYER 1                 PLAYER 2")
                    .font(.system(size: h * 0.023, weight: .heavy)).foregroundStyle(.white)
                Text("\(state.shots.count) shots played · five each")
                    .font(.system(size: h * 0.027, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            } else if model.territoryDuel != nil || model.copyMyShot != nil {
                Text("\(model.partyScore(.one)) – \(model.partyScore(.two))")
                    .font(.system(size: h * 0.13, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text("PLAYER 1                 PLAYER 2")
                    .font(.system(size: h * 0.023, weight: .heavy)).foregroundStyle(.white)
                Text(model.territoryDuel != nil ? "ZONES OWNED · \(model.territoryDuel!.shots) SHOTS" : "\(model.copyMyShot!.challenges.count) CHALLENGES PLAYED")
                    .font(.system(size: h * 0.027, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            } else if let state = model.fourInRow {
                Text(state.winner != nil ? "FOUR CONNECTED" : state.finished ? "FULL BOARD" : "PLAY AGAIN")
                    .font(.system(size: h * 0.052, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text("\(state.cells.count) chips played")
                    .font(.system(size: h * 0.030, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            } else {
                Text(model.partyFinished ? (model.partyWinner == nil ? "FULL BOARD" : "THREE IN A ROW") : "PLAY AGAIN")
                    .font(.system(size: h * 0.052, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text("\(model.crossCircle?.cells.count ?? 0) squares claimed")
                    .font(.system(size: h * 0.030, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            }
            Text("Swap sides. Play the rematch.")
                .font(.system(size: h * 0.030, weight: .medium)).foregroundStyle(.white)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultDetails(height h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.022) {
            Label(model.game.isArcade ? arcadeResultTitle
                  : cleared ? (model.isNewBest ? (model.previousBest == nil ? "FIRST CLEAR!" : "NEW PERSONAL BEST!") : "WALL CLEARED!") : "ROUND STOPPED",
                  systemImage: cleared ? "trophy.fill" : "pause.circle.fill")
                .font(.system(size: h * 0.03, weight: .black, design: .rounded))
                .foregroundStyle(gold)
            Text(model.game.isArcade ? "\(model.arcadeScore)" : time(model.elapsed(at: .now)))
                .font(.system(size: h * 0.10, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(model.game.isArcade ? arcadeResultDetail
                 : "\(model.clearedBoxes.count) / \(model.game.targetCount) \(model.game == .brickBlast ? "broken" : "cleared")  ·  \(model.hits.count) hits")
                .font(.system(size: h * 0.029, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if model.game.isArcade {
                Text("BEST ON THIS PHONE  \(model.bestArcadeScore)")
                    .font(.system(size: h * 0.025, weight: .bold, design: .rounded)).foregroundStyle(gold)
            } else if let best = model.bestClearTime {
                Text("BEST ON THIS PHONE  " + time(best))
                    .font(.system(size: h * 0.025, weight: .bold, design: .rounded))
                    .foregroundStyle(gold)
            }
            Text(model.game.isArcade ? "Your results are kept. Ready to go again?"
                 : cleared ? "Wall cleared. Can you beat that?" : "Your contacts are kept. Try another round.")
                .font(.system(size: h * 0.027, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func targetMap(height h: CGFloat) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = size.height
            ZStack(alignment: .topLeading) {
                if model.game == .memoryStrike {
                    WallMemoryBoard(state: results ? model.memory ?? .init(seed: 17) : .init(seed: 17),
                                    time: results ? model.arcadeTime() : 1.5)
                } else if model.game == .meteorDefence {
                    WallMeteorBoard(state: results ? model.meteors ?? .init(seed: 17) : .init(seed: 17),
                                    time: results ? model.arcadeTime() : 8.4)
                } else if model.game == .crossCircle {
                    WallCrossCircleBoard(state: results ? model.crossCircle ?? .init() : .preview, time: 10)
                } else if model.game == .goalDuel {
                    WallGoalDuelBoard(state: results ? model.goalDuel ?? .init() : .init(),
                                      time: results ? model.arcadeTime() : 1.8)
                } else if model.game == .fourInRow {
                    WallFourInRowBoard(state: results ? model.fourInRow ?? .init() : .preview, time: results ? model.arcadeTime() : 100)
                } else if model.game == .territoryDuel {
                    WallTerritoryBoard(state: results ? model.territoryDuel ?? .init() : .preview, time: results ? model.arcadeTime() : 100)
                } else if model.game == .copyMyShot {
                    WallCopyShotBoard(state: results ? model.copyMyShot ?? .init() : .preview, time: results ? model.arcadeTime() : 100)
                } else {
                ForEach(model.game.layout.targets) { target in
                    let box = target.id
                    let frame = target.screenFrame(in: CGRect(origin: .zero, size: size))
                    let hit = results ? model.boxesHit.contains(box) : box == 4 || box == 5
                    let tint = hit ? gold : cyan
                    ZStack {
                        if model.game == .brickBlast {
                            WallBrickTile(health: results ? model.remainingHealth(for: box)
                                          : box == 1 ? 1 : box == 9 ? 0 : model.game.initialHealth(for: box),
                                          initialHealth: model.game.initialHealth(for: box), seed: box,
                                          impact: mapImpact(box))
                        } else {
                        RoundedRectangle(cornerRadius: unit * 0.035).fill(tint.opacity(0.13))
                        RoundedRectangle(cornerRadius: unit * 0.035).strokeBorder(tint, lineWidth: unit * 0.009)
                        Text(hit ? "✓" : "\(box)")
                            .font(.system(size: unit * 0.22, weight: .black, design: .rounded))
                            .foregroundStyle(tint)
                        }
                    }
                    .frame(width: max(1, frame.width - (model.game == .brickBlast ? 0 : unit * 0.025)),
                           height: max(1, frame.height - (model.game == .brickBlast ? 0 : unit * 0.025)))
                    .position(x: frame.midX, y: frame.midY)
                }
                if results {
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                        Text("\(index + 1)")
                            .font(.system(size: unit * 0.047, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: unit * 0.085, height: unit * 0.085)
                            .background(.black, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: unit * 0.005))
                            .position(x: hit.u / 3 * size.width, y: hit.v / 2 * size.height)
                    }
                }
                }
            }
            .clipped()
        }
        .accessibilityLabel(results ? "Hit map, \(model.clearedBoxes.count) of \(model.game.targetCount) targets cleared" : "Example board with \(model.game.targetCount) targets")
    }

    private var mapTitle: String {
        switch model.game {
        case .clearTheWall: "SIX TARGETS. ONE WALL."
        case .brickBlast: "THIRTY BRICKS. ONE WALL."
        case .memoryStrike: "YOUR MEMORY. YOUR NEXT MOVE."
        case .meteorDefence: "THREE WAVES. ONE CITY."
        case .crossCircle: "CLAIM IT. BLOCK THEM. MAKE THREE."
        case .goalDuel: "ONE KEEPER. TWO CHALLENGERS."
        case .fourInRow: "DROP IT. CONNECT IT. WIN."
        case .territoryDuel: "THIRTEEN ZONES. ONE WINNER."
        case .copyMyShot: "YOUR SPOT. THEIR CHALLENGE."
        }
    }
    private var arcadeResultTitle: String {
        if model.arcadeWon == nil { return "ROUND STOPPED" }
        if model.arcadeWon == false { return model.game == .memoryStrike ? "GOOD TRY!" : "CITY LOST" }
        return model.game == .memoryStrike ? "MEMORY MASTER!" : "CITY SAVED!"
    }
    private var arcadeResultDetail: String {
        if let memory = model.memory { return "\(memory.completedRounds) / 5 rounds  ·  \(memory.lives) lives left" }
        return "\(model.meteors?.destroyed ?? 0) meteors stopped  ·  \(model.meteors?.shields ?? 0) shields left"
    }

    private func mapImpact(_ box: Int) -> CGPoint {
        guard results, let hit = model.hits.last(where: { $0.brickDamage.contains { $0.id == box } }) else {
            return CGPoint(x: 0.4, y: 0.4)
        }
        guard let frame = model.game.layout.target(box)?.frame else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (hit.u - frame.minX) / frame.width, y: (hit.v - frame.minY) / frame.height)
    }

    private func primaryAction(height h: CGFloat) -> some View {
        let enabled = startEnabled && model.canStartGame
        let title = model.recordingState == .saving || model.recordingState == .recording ? "Saving…"
            : results ? "Play again" : "Set up & play"
        return Group {
            if let onStart {
                Button(action: onStart) {
                    Label(title, systemImage: results ? "arrow.counterclockwise" : "play.fill")
                        .font(.system(size: h * 0.029, weight: .heavy, design: .rounded))
                        .padding(.horizontal, h * 0.03)
                        .frame(height: max(44, h * 0.09))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(enabled ? cyan : .gray, in: RoundedRectangle(cornerRadius: h * 0.016))
                .disabled(!enabled)
                .accessibilityIdentifier("wall-game-start")
            } else {
                Label(enabled ? (results ? "Play again on your phone" : "Start on your phone") : title,
                      systemImage: "iphone")
                    .font(.system(size: h * 0.026, weight: .bold))
                    .foregroundStyle(cyan)
            }
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", max(0, seconds))
    }
}
#endif
