#if WALL_GAMES_PREVIEW
import SwiftUI

struct WallArcadeRoundScreen: View {
    @ObservedObject var model: WallTargetsModel
    let startEnabled: Bool
    let startStatus: String?
    let saveFinished: Bool
    let savedFolder: URL?
    let onStart: () -> Void
    let onClose: () -> Void
    let onSetup: () -> Void
    @State private var showReplay=false
    private var results: Bool { model.gameScreen == .results }
    private var value: String {
        if model.game.isParty {
            if [.goalDuel,.territoryDuel,.copyMyShot].contains(model.game) { return "\(model.partyScore(.one)) – \(model.partyScore(.two))" }
            return model.partyWinner.map { model.game == .crossCircle ? $0.mark : "P\($0.rawValue)" } ?? (model.partyFinished ? "DRAW":"—")
        }
        if model.game == .brickBlast { return "\(model.brickScore)" }
        if model.game.isArcade { return "\(model.arcadeScore)" }
        return String(format:"%.1f",model.elapsed(at:.now))+"s"
    }
    private var resultTitle: String {
        if model.game.isParty { return model.partyResultTitle }
        if model.isNewBest { return "NEW PERSONAL BEST" }
        if model.clearedAt != nil { return "WALL CLEARED" }
        if model.arcadeWon != nil { return model.arcadeWon == true ? "CHALLENGE COMPLETE":"GAME OVER" }
        return "ROUND STOPPED"
    }
    var body: some View {
        GeometryReader { geo in
            let compact=geo.size.height<380
            VStack(alignment:.leading,spacing:compact ? 12:18) {
                HStack {
                    Button(action:onClose) {
                        Image(systemName:"chevron.left").font(.system(size:18,weight:.medium)).frame(width:32,height:32)
                    }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).tint(.white)
                        .disabled(!saveFinished).accessibilityLabel("Back to all games").accessibilityIdentifier("arcade-round-back")
                    Spacer()
                    if !results {
                        Button(action:onSetup) { Label("View camera & setup",systemImage:"camera.viewfinder").font(.caption.bold()) }
                            .buttonStyle(.glass).tint(.white).accessibilityIdentifier("arcade-round-setup")
                    }
                    Text("JUGGLE DUDE / WALL ARCADE").font(.system(size:10,weight:.bold)).tracking(1.8).foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing:32) {
                    VStack(alignment:.leading,spacing:8) {
                        Text(results ? resultTitle:(model.game.isParty ? "2 PLAYERS · ONE BALL":"SOLO CHALLENGE"))
                            .font(.system(size:11,weight:.heavy)).tracking(1.4).foregroundStyle(WallArcadeStyle.lime)
                        Text(model.game.title.uppercased()).font(WallArcadeStyle.display(compact ? 36:44)).lineLimit(1).minimumScaleFactor(0.6)
                        if results {
                            Text(value).font(WallArcadeStyle.display(compact ? 58:72)).monospacedDigit()
                            Text(model.game == .brickBlast ? "POINTS · \(model.clearedBoxes.count)/\(model.game.targetCount) BRICKS":model.game.isArcade && !model.game.isParty ? "POINTS":"\(model.hits.count) CONFIRMED SHOTS")
                                .font(.caption.bold()).foregroundStyle(.white.opacity(0.6))
                        } else {
                            Text(model.game.instructions).font(.system(size:14)).foregroundStyle(.white.opacity(0.75)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:0)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    WallArcadeArtwork(game:model.game).aspectRatio(1.6,contentMode:.fit).frame(width:geo.size.width*0.40)
                        .clipShape(.rect(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(.white.opacity(0.12)))
                }.frame(maxHeight:.infinity)
                Rectangle().fill(.white.opacity(0.12)).frame(height:1)
                HStack(spacing:12) {
                    Button(action:onStart) {
                        HStack(spacing:14) { Text(results ? "Play again":"Let's play");Image(systemName:results ? "arrow.clockwise":"arrow.right") }
                            .font(.subheadline.bold()).padding(.horizontal,12).frame(minHeight:40)
                    }.buttonStyle(.glassProminent).tint(TrainingHomeStyle.lime)
                        .foregroundStyle(startEnabled ? TrainingHomeStyle.buttonInk : Color.white).disabled(!startEnabled)
                        .accessibilityIdentifier("arcade-start-round")
                    if results {
                        Button { showReplay=true } label: { Label("Replay & share",systemImage:"play.rectangle").font(.subheadline.bold()).frame(minHeight:40) }
                            .buttonStyle(.glass).tint(.white)
                            .disabled(savedFolder==nil || !saveFinished).accessibilityIdentifier("arcade-open-round")
                    }
                    Spacer(minLength:8)
                    VStack(alignment:.trailing,spacing:4) {
                        if results && !saveFinished { Text("Saving your round…") }
                        else if results && savedFolder != nil { Label("Round saved",systemImage:"checkmark.circle.fill").foregroundStyle(WallArcadeStyle.lime) }
                        else if results { Text("No replay saved").foregroundStyle(.orange) }
                        else { Text(model.hasReusableSetup ? "Quick alignment check":"Guided setup · one ball hold") }
                        Text(startStatus ?? (model.hasReusableSetup ? "Phone still in place? You're ready.":"Keep all four corner dots visible."))
                            .foregroundStyle(.white.opacity(0.55))
                    }.font(.system(size:11,weight:.medium)).multilineTextAlignment(.trailing)
                }
            }.padding(.horizontal,28).padding(.vertical,12)
        }.background(WallArcadeStyle.background).foregroundStyle(.white).tint(WallArcadeStyle.lime)
            .sheet(isPresented:$showReplay) {
                if let folder=savedFolder,let record=WallArcadeRecord(folder:folder) {
                    NavigationStack { WallArcadeReplay(record:record).toolbar { ToolbarItem(placement:.topBarTrailing) {
                        Button("Close replay",systemImage:"xmark") { showReplay=false }.labelStyle(.iconOnly)
                    } } }
                }
            }
    }
}
#endif
