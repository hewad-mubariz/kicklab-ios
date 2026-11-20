#if WALL_GAMES_PREVIEW
import AVKit
import SwiftUI

struct WallArcadeHistory: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records=WallArcadeRecord.all()
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing:14) {
                    if records.isEmpty {
                        ContentUnavailableView("Your next round starts here",systemImage:"play.rectangle",description:Text("Play a game and your result and replay will be saved on this iPhone."))
                    }
                    ForEach(records) { record in
                        NavigationLink { WallArcadeReplay(record:record) } label: {
                            HStack(spacing:14) {
                                WallArcadeArtwork(game:record.game).frame(width:100,height:76).clipShape(.rect(cornerRadius:12))
                                VStack(alignment:.leading,spacing:5) {
                                    Text(record.title).font(.headline)
                                    Text(record.completed ? record.headline.capitalized:"Stopped round").font(.caption).foregroundStyle(WallArcadeStyle.lime)
                                    Text(record.created.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength:0)
                                Image(systemName:"chevron.right").font(.caption.bold())
                            }.padding(12).background(WallArcadeStyle.panel,in:.rect(cornerRadius:18))
                        }.buttonStyle(.plain).accessibilityIdentifier("arcade-record-"+record.folder.lastPathComponent)
                    }
                }.padding(20)
            }.background(WallArcadeStyle.background).foregroundStyle(.white)
                .navigationTitle("Your replays")
                .toolbar { ToolbarItem(placement:.topBarTrailing) {
                    Button("Close replays",systemImage:"xmark") { dismiss() }
                        .labelStyle(.iconOnly).accessibilityIdentifier("arcade-history-close")
                } }
        }.preferredColorScheme(.dark).tint(WallArcadeStyle.lime)
    }
}

struct WallArcadeReplay: View {
    let record: WallArcadeRecord
    @State private var player: AVPlayer?
    @State private var share: ArcadeShareItem?
    @State private var exportError: String?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                WallArcadeResultCard(record:record).clipShape(.rect(cornerRadius:22))
                if let player {
                    VideoPlayer(player:player).aspectRatio(16/9,contentMode:.fit).clipShape(.rect(cornerRadius:16))
                    Text("Original camera replay · saved on this iPhone").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(record.finalized ? "Replay unavailable":"Recording was interrupted. The original files are kept for recovery.",systemImage:"video.slash").font(.callout).foregroundStyle(.secondary)
                }
                if let exportError { Text(exportError).font(.caption).foregroundStyle(.orange) }
                Text("\(record.hits) confirmed shots · \(record.clock) active play. Setup and alignment pauses are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth:680).frame(maxWidth:.infinity)
        }.background(WallArcadeStyle.background).foregroundStyle(.white)
            .safeAreaInset(edge:.bottom,spacing:0) {
                shareActions.padding(.horizontal,20).padding(.vertical,12)
                    .background(WallArcadeStyle.background)
            }
            .navigationTitle(record.title).navigationBarTitleDisplayMode(.inline)
            .tint(WallArcadeStyle.lime).preferredColorScheme(.dark)
            .sheet(item:$share) { ArcadeShareSheet(items:$0.items) }
            .task(id:record.id) {
                guard let url=record.video else { return }
                let value=AVPlayer(url:url)
                player=value
                await value.seek(to:CMTime(seconds:max(0,record.playStart),preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
            }
            .onDisappear { player?.pause();player?.replaceCurrentItem(with:nil);player=nil }
    }
    private var shareActions: some View {
        HStack(spacing:12) {
                    Button { shareResult() } label: { Label("Share result",systemImage:"square.and.arrow.up").frame(maxWidth:.infinity,minHeight:46) }
                        .buttonStyle(.glassProminent).tint(TrainingHomeStyle.lime).foregroundStyle(TrainingHomeStyle.buttonInk)
                        .accessibilityIdentifier("arcade-share-result")
                    if let video=record.video {
                        Button { player?.pause();share=ArcadeShareItem(items:[video]) } label: { Label("Share video",systemImage:"film").frame(maxWidth:.infinity,minHeight:46) }.buttonStyle(.glass).tint(.white)
                            .accessibilityIdentifier("arcade-share-video")
                    }
                }
    }
    @MainActor private func shareResult() {
        player?.pause()
        let renderer=ImageRenderer(content:WallArcadeResultCard(record:record).frame(width:540).environment(\.colorScheme,.dark))
        renderer.scale=2
        guard let data=renderer.uiImage?.pngData() else { exportError="Could not prepare the result. Please try again.";return }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("JuggleDude-\(record.folder.lastPathComponent)-result.png")
        do { try data.write(to:url,options:.atomic);share=ArcadeShareItem(items:[url]);exportError=nil }
        catch { exportError=error.localizedDescription }
    }
}

struct WallArcadeResultCard: View {
    let record: WallArcadeRecord
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text("JUGGLE DUDE").font(WallArcadeStyle.display(25));Spacer();Text("WALL ARCADE").font(.caption2.bold()).tracking(1).foregroundStyle(WallArcadeStyle.lime) }.padding(22)
            WallArcadeArtwork(game:record.game).aspectRatio(2.3,contentMode:.fit)
            VStack(alignment:.leading,spacing:10) {
                Text(record.title.uppercased()).font(WallArcadeStyle.display(34))
                Text(record.headline).font(.caption.bold()).tracking(1.4).foregroundStyle(WallArcadeStyle.lime)
                Text(record.value).font(WallArcadeStyle.display(88)).monospacedDigit()
                Text(record.detail).font(.caption.bold()).tracking(1).foregroundStyle(.white.opacity(0.7))
                Rectangle().fill(.white.opacity(0.12)).frame(height:1).padding(.vertical,10)
                HStack { Text("Your wall. Your game.");Spacer();Text(record.created.formatted(date:.abbreviated,time:.omitted)) }.font(.caption2).foregroundStyle(.white.opacity(0.5))
            }.padding(22)
        }.background(WallArcadeStyle.panel).foregroundStyle(.white)
    }
}

struct ArcadeShareItem: Identifiable { let id=UUID();let items:[Any] }
struct ArcadeShareSheet: UIViewControllerRepresentable {
    let items:[Any]
    func makeUIViewController(context:Context) -> UIActivityViewController { UIActivityViewController(activityItems:items,applicationActivities:nil) }
    func updateUIViewController(_ controller:UIActivityViewController,context:Context) { }
}
#endif
