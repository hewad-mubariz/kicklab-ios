import AVFoundation
import SwiftUI

struct ExportOverlayLayer: View {
    let settings: ExportOverlaySettings
    let timeline: ExportCounterTimeline
    let time: Double
    let size: CGSize

    var body: some View {
        if settings.counter.enabled,
           let badge = ExportOverlayRenderer.image(style: settings.counter.style,
                time: time, counter: timeline.state(at: time)) {
            let rect = settings.counter.placement.rect(in: size)
            Image(decorative: badge, scale: 1).resizable()
                .frame(width: rect.width, height: rect.height)
                .rotationEffect(.radians(settings.counter.placement.radians))
                .position(x: rect.midX, y: rect.midY)
                // Pops in and out around the sticker's own center, not the canvas center.
                .transition(.sessionPop(from: UnitPoint(x: rect.midX / max(1, size.width),
                                                        y: rect.midY / max(1, size.height)), scale: 0.4))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct ExportOverlayEditor: View {
    @ObservedObject var preparation = SessionEffectsPreparation()
    let summary: SessionSummary
    let edit: SessionEditState
    let sourceSize: CGSize
    @ObservedObject var sceneModel: StadiumPreviewModel
    @Binding var settings: ExportOverlaySettings
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var observer: Any?
    @State private var time: Double = 0
    @State private var duration: Double = 1
    @State private var playing = false
    @State private var wasPlaying = false
    @State private var scrubbing = false
    @State private var error: String?
    @State private var effectTrack = BallEffectTrack(frames: [])
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var timeline: ExportCounterTimeline { .init(touches: summary.touchesMarked, total: summary.touches) }
    private var item: Binding<ExportOverlayItem> {
        $settings.counter
    }

    var body: some View {
        GeometryReader { screen in
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Make it yours").font(.system(size: 23, weight: .bold))
                        Text("Touch counter sticker").font(.system(size: 12)).foregroundStyle(SessionStyle.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(SessionStyle.mint)
                        .accessibilityIdentifier("counter-editor-done")
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 14)
                VStack(spacing: 10) {
                    canvas.frame(height: min(380, screen.size.height * 0.40))
                    playback
                    Text("Drag to move · Pinch to resize · Twist to rotate")
                        .font(.system(size: 11)).foregroundStyle(SessionStyle.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 14)
                ScrollView {
                    VStack(spacing: 12) {
                        Toggle("Show counter", isOn: item.enabled.animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)))
                            .font(.system(size: 14, weight: .semibold)).tint(SessionStyle.mint)
                            .accessibilityIdentifier("counter-show")
                        // Placement is direct on the canvas above; only the look is chosen here.
                        CounterStyleGrid(item: item)
                        if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 28)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(.white).background(SessionStyle.background)
        }
        .preferredColorScheme(.dark)
        .task { await prepare() }
        .onDisappear {
            player?.pause()
            if let observer { player?.removeTimeObserver(observer) }
            observer = nil; player = nil
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let factor = min(geometry.size.width / sourceSize.width, geometry.size.height / sourceSize.height)
            let size = CGSize(width: sourceSize.width * factor, height: sourceSize.height * factor)
            ZStack(alignment: .topLeading) {
                Color.black
                if let player {
                    MetalVideoSurface(player: player, edit: edit, track: effectTrack) { error = $0 }
                } else {
                    VStack(spacing: 10) {
                        if let error { Text(error).font(.system(size: 12)).multilineTextAlignment(.center) }
                        else {
                            ProgressView().tint(SessionStyle.mint)
                            Text(sceneModel.isRendering ? "Rendering your environment…" : "Preparing video…")
                                .font(.system(size: 11)).foregroundStyle(SessionStyle.secondary)
                            if sceneModel.isRendering {
                                Text("\(Int(sceneModel.renderProgress * 100))%")
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(SessionStyle.mint)
                            }
                        }
                    }.padding(10).frame(width: size.width, height: size.height)
                }
                if settings.counter.enabled {
                    ExportOverlayLayer(settings: settings, timeline: timeline, time: time, size: size)
                    let rect = settings.counter.placement.rect(in: size)
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SessionStyle.mint.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: rect.width, height: rect.height)
                        .rotationEffect(.radians(settings.counter.placement.radians))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    CounterStickerInteraction(placement: $settings.counter.placement)
                        .frame(width: size.width, height: size.height)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size.width, height: size.height).clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SessionStyle.rim, lineWidth: 0.8))
    }

    private var playback: some View {
        HStack(spacing: 12) {
            Button {
                guard let player else { return }
                if playing { player.pause(); playing = false }
                else {
                    if time >= duration - 0.05 { time = 0; player.seek(to: .zero) }
                    player.play(); playing = true
                }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 28, height: 32)
            }.accessibilityLabel(playing ? "Pause overlay preview" : "Play overlay preview")
            Text(ExportPreviewTime.label(at: time)).font(.system(size: 11, weight: .semibold, design: .monospaced))
            Slider(value: Binding(get: { time }, set: { time = $0; seek() }), in: 0...max(0.1, duration)) { editing in
                scrubbing = editing
                if editing { wasPlaying = playing; player?.pause() }
                else if wasPlaying { player?.play() }
            }.tint(SessionStyle.mint).accessibilityLabel("Overlay preview position")
        }
    }

    private func seek() {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func prepare() async {
        do {
            let ready = edit.ballSkin != .original ? try await preparation.prepare(summary) : summary
            let media = try await sceneModel.media(summary: ready, selection: edit.scene)
            let url = media.url
            effectTrack = BallEffectTrack(frames: media.track, touchTimes: summary.touchesMarked.map(\.time))
            if edit.ballSkin != .original {
                effectTrack.surfaceMotion = try await BallSurfaceTimeline.prepare(source: ready.videoURL, track: BallEffectTrack(frames: ready.renderTrack))
            }
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration)
            try Task.checkCancellation()
            duration = max(0.1, CMTimeGetSeconds(length))
            let item = AVPlayerItem(asset: asset)
            if let video = try await asset.loadTracks(withMediaType: .video).first {
                item.videoComposition = try await EffectVideoGeometry.composition(track: video, duration: length, shortEdge: 1080)
            }
            try Task.checkCancellation()
            let next = AVPlayer(playerItem: item)
            next.actionAtItemEnd = .pause
            player = next
            observer = next.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 24), queue: .main) { stamp in
                Task { @MainActor in
                    if !scrubbing { time = max(0, CMTimeGetSeconds(stamp)) }
                    if time >= duration - 0.05 { playing = false }
                }
            }
        } catch is CancellationError { }
        catch { self.error = "Couldn’t prepare the preview: \(error.localizedDescription)" }
    }
}
