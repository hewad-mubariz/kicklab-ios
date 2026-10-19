#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

/// The phone and external display share the same game presentation. Only the
/// phone supplies actions; the wall tells the player where to start the round.
struct WallTargetsGameScreen: View {
    @ObservedObject var model: WallTargetsModel
    var onStart: (() -> Void)?
    var onSettings: (() -> Void)?
    var startEnabled = true
    var startStatus: String?

    private let cyan = WallTargetsBoard.metalCyan
    private let gold = WallTargetsBoard.metalGold
    private var results: Bool { model.gameScreen == .results }
    private var cleared: Bool { model.clearedAt != nil }

    var body: some View {
        GeometryReader { geometry in
            let h = geometry.size.height
            let w = geometry.size.width * 0.76
            VStack(alignment: .leading, spacing: h * 0.035) {
                HStack {
                    Text("KICKLAB  /  WALL GAMES")
                        .tracking(h * 0.003)
                    Spacer()
                    Text("01  ·  SOLO TIME TRIAL")
                }
                .font(.system(size: h * 0.022, weight: .bold))
                .foregroundStyle(cyan)

                HStack(alignment: .center, spacing: w * 0.07) {
                    if results { resultDetails(height: h) }
                    else { introduction(height: h) }
                    VStack(alignment: .leading, spacing: h * 0.022) {
                        Text(results ? "YOUR HIT MAP" : "SIX TARGETS. ONE WALL.")
                            .font(.system(size: h * 0.023, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.7))
                        targetMap(height: h)
                            .aspectRatio(1.5, contentMode: .fit)
                        Text(results ? "Numbered marks show confirmed contacts." : "Hit every target in any order. Gold means cleared.")
                            .font(.system(size: h * 0.025, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: w * 0.40)
                }
                .frame(height: h * 0.48)

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

    private func introduction(height h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.026) {
            Text("CLEAR\nTHE WALL")
                .font(.system(size: h * 0.102, weight: .black, design: .rounded))
                .lineSpacing(-h * 0.014)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.75)
            Text("Six targets. Your fastest time.")
                .font(.system(size: h * 0.031, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Label(model.bestClearTime.map { "BEST ON THIS PHONE  " + time($0) } ?? "Set your first personal best",
                  systemImage: "trophy.fill")
                .font(.system(size: h * 0.026, weight: .bold, design: .rounded))
                .foregroundStyle(gold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultDetails(height h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.022) {
            Label(cleared ? (model.isNewBest ? (model.previousBest == nil ? "FIRST CLEAR!" : "NEW PERSONAL BEST!") : "WALL CLEARED!") : "ROUND STOPPED",
                  systemImage: cleared ? "trophy.fill" : "pause.circle.fill")
                .font(.system(size: h * 0.03, weight: .black, design: .rounded))
                .foregroundStyle(gold)
            Text(time(model.elapsed(at: .now)))
                .font(.system(size: h * 0.10, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("\(model.boxesHit.count) / 6 cleared  ·  \(model.hits.count) confirmed hits")
                .font(.system(size: h * 0.029, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if let best = model.bestClearTime {
                Text("BEST ON THIS PHONE  " + time(best))
                    .font(.system(size: h * 0.025, weight: .bold, design: .rounded))
                    .foregroundStyle(gold)
            }
            Text(cleared ? "Wall cleared. Can you beat that?" : "Your contacts are kept. Try another round.")
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
                ForEach(1...6, id: \.self) { box in
                    let hit = results ? model.boxesHit.contains(box) : box == 4 || box == 5
                    let tint = hit ? gold : cyan
                    ZStack {
                        RoundedRectangle(cornerRadius: unit * 0.035).fill(tint.opacity(0.13))
                        RoundedRectangle(cornerRadius: unit * 0.035).strokeBorder(tint, lineWidth: unit * 0.009)
                        Text(hit ? "✓" : "\(box)")
                            .font(.system(size: unit * 0.22, weight: .black, design: .rounded))
                            .foregroundStyle(tint)
                    }
                    .frame(width: size.width / 3 - unit * 0.025, height: size.height / 2 - unit * 0.025)
                    .position(x: (CGFloat((box - 1) % 3) + 0.5) * size.width / 3,
                              y: (CGFloat((box - 1) / 3) + 0.5) * size.height / 2)
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
            .clipped()
        }
        .accessibilityLabel(results ? "Hit map, \(model.boxesHit.count) of six targets cleared" : "Example board with six targets")
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
