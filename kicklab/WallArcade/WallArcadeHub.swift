#if WALL_GAMES_PREVIEW
import SwiftUI

struct WallArcadeHomeCard: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image("home-wall-arcade").resizable().aspectRatio(2,contentMode:.fit)
                    .accessibilityHidden(true)
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text("03 / PLAY TOGETHER").font(.system(size:9,weight:.semibold)).tracking(0.6)
                        Text("WALL ARCADE").font(WallArcadeStyle.display(30)).foregroundStyle(.white)
                        Text("One ball. A whole new playground.").font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength:0)
                    Image(systemName:"arrow.right").font(.system(size:18,weight:.semibold))
                }.padding(.horizontal,14).padding(.vertical,16)
                    .frame(maxWidth:.infinity,minHeight:78)
                    .foregroundStyle(WallArcadeStyle.lime)
            }
            .background(TrainingHomeStyle.cardFooter)
            .foregroundStyle(.white).clipShape(.rect(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(.white.opacity(0.09)))
        }.buttonStyle(.plain).accessibilityIdentifier("module-wall-arcade")
            .accessibilityLabel("Wall Arcade, Choose a game")
            .accessibilityHint("One ball. A whole new playground.")
    }
}

struct WallArcadeHub: View {
    @ObservedObject var model: WallTargetsModel
    @ObservedObject var camera: WallTargetsCamera
    let onPlay: (WallGame) -> Void
    let onTopBins: () -> Void
    let onClose: () -> Void
    @State private var filter = 0
    @State private var history = false
    @State private var guide = false
    @AppStorage("wallTargets.hitSoundsEnabled") private var sounds = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    private var compact: Bool { verticalSize == .compact }
    private var games: [WallArcadeGame] {
        WallArcadeGame.all.filter { filter == 0 || $0.twoPlayers == (filter == 2) }
    }
    private var navigationBar: some View {
        HStack {
            Button(action:onClose) {
                Image(systemName:"chevron.left").font(.system(size:18,weight:.medium))
                    .frame(width:32,height:32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).tint(.white)
                .accessibilityLabel("Back to training").accessibilityIdentifier("arcade-back")
            if compact { Text("WALL ARCADE").font(WallArcadeStyle.display(32)).padding(.leading,12) }
            Spacer()
            Button { history=true } label: {
                Image(systemName:"play.rectangle.on.rectangle").font(.system(size:18))
                    .frame(width:32,height:32)
            }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).tint(.white)
                .accessibilityLabel("Replays").accessibilityIdentifier("arcade-replays")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:compact ? 12:22) {
                if !compact { VStack(alignment:.leading,spacing:6) {
                    Text("JUGGLE DUDE / PLAY").font(.caption2.bold()).tracking(2).foregroundStyle(WallArcadeStyle.lime)
                    Text("WALL ARCADE").font(WallArcadeStyle.display(56))
                    Text("Turn your wall into a playground.").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }
                }
                Button { model.arcadeSetupGuidePresented=true;guide=true } label: {
                    HStack(spacing:12) {
                        Image(systemName:model.hasReusableSetup ? "checkmark.viewfinder":"viewfinder").font(.title2).foregroundStyle(WallArcadeStyle.lime)
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.hasReusableSetup ? "Check your setup":"Set up your wall").font(.subheadline.bold())
                            Text(model.projectorConnected ? "Separate display connected · View camera":"Connect a display · View camera")
                                .font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer(minLength:0);Image(systemName:"chevron.right").font(.caption.bold())
                    }.padding(16).background(WallArcadeStyle.panel,in:.rect(cornerRadius:18))
                }.buttonStyle(.plain).accessibilityIdentifier("arcade-setup-guide")
                Picker("Players",selection:$filter) {
                    Text("All games").tag(0);Text("Solo").tag(1);Text("2 players").tag(2)
                }.pickerStyle(.segmented)
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:typeSize.isAccessibilitySize ? 1:(compact ? 3:2)),spacing:16) {
                    ForEach(games) { entry in
                        Button { if let game=entry.game { onPlay(game) } else { onTopBins() } } label: {
                            VStack(alignment:.leading,spacing:0) {
                                WallArcadeArtwork(game:entry.game).aspectRatio(1.48,contentMode:.fit)
                                VStack(alignment:.leading,spacing:7) {
                                    Text(entry.twoPlayers ? "2 PLAYERS":"SOLO").font(.system(size:9,weight:.heavy)).tracking(1).foregroundStyle(WallArcadeStyle.lime)
                                    Text(entry.title.uppercased()).font(WallArcadeStyle.display(25)).lineLimit(1).minimumScaleFactor(0.7)
                                    Text(entry.subtitle).font(.system(size:11)).foregroundStyle(.white.opacity(0.65)).lineLimit(2).frame(height:30,alignment:.topLeading)
                                    HStack { Text("Play").font(.caption.bold());Spacer();Image(systemName:"arrow.up.right").font(.caption.bold()) }.padding(.top,7)
                                }.padding(13)
                            }.background(WallArcadeStyle.panel).clipShape(.rect(cornerRadius:17))
                                .overlay(RoundedRectangle(cornerRadius:17).stroke(.white.opacity(0.08)))
                        }.buttonStyle(.plain).accessibilityIdentifier("arcade-game-"+entry.id)
                    }
                }
                HStack {
                    Label("Hit sounds",systemImage:sounds ? "speaker.wave.2":"speaker.slash")
                    Spacer();Toggle("Hit sounds",isOn:$sounds).labelsHidden().tint(WallArcadeStyle.lime)
                }.font(.subheadline).padding(16).background(WallArcadeStyle.panel,in:.rect(cornerRadius:16))
                Text("Rounds save automatically on this iPhone. Open Replays to watch or share.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55)).lineSpacing(3)
            }.padding(20).frame(maxWidth:compact ? 1000:600).frame(maxWidth:.infinity)
        }
        .background(WallArcadeStyle.background.ignoresSafeArea()).foregroundStyle(.white)
        .safeAreaInset(edge:.top,spacing:0) {
            navigationBar.padding(.horizontal,20).padding(.top,12).padding(.bottom,10)
                .foregroundStyle(.white).background(WallArcadeStyle.background)
        }
        .preferredColorScheme(.dark).tint(WallArcadeStyle.lime)
        .sheet(isPresented:$history) { WallArcadeHistory() }
        .fullScreenCover(isPresented:$guide,onDismiss:{
            camera.setFramingPreview(false)
            model.arcadeSetupGuidePresented=false
            WallTargetsAppDelegate.lock(.allButUpsideDown)
        }) { WallArcadeSetupGuide(model:model,camera:camera) }
        .accessibilityIdentifier("wall-arcade-hub")
    }
}

/// Browsing and sharing stay on the phone; the projector stays clean.
struct WallArcadeProjectorWelcome: View {
    var body: some View {
        GeometryReader { g in
            VStack(spacing:g.size.height*0.04) {
                Text("JUGGLE DUDE / PLAY").font(.system(size:g.size.height*0.035,weight:.bold)).tracking(4).foregroundStyle(WallArcadeStyle.lime)
                Text("WALL ARCADE").font(WallArcadeStyle.display(g.size.height*0.17))
                Text("Choose a game on your phone").font(.system(size:g.size.height*0.045,weight:.semibold))
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.foregroundStyle(.white).background(.black).ignoresSafeArea()
    }
}
#endif
